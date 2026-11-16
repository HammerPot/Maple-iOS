import Foundation
import Observation

@MainActor @Observable
final class AppServices {
    let http: MapleHTTP
    let api: MapleAPI
    let auth: AuthSessionModel
    let realtime: MapleRealtime
    let playback: PlaybackReporter
    let friends: FriendsModel
    let toasts = ToastCenter()
    private var signedInID: String?

    init() {
        UserDefaults.standard.register(defaults: ["socketIO": true])
        let http = MapleHTTP()
        self.http = http
        let api = MapleAPI(http: http)
        self.api = api
        auth = AuthSessionModel(api: api)
        friends = FriendsModel(api: api)
        let realtime = MapleRealtime()
        self.realtime = realtime
        let toasts = self.toasts
        playback = PlaybackReporter(transport: realtime, upload: { try await api.setAlbumArt($0, playbackId: $1) }, reportError: { toasts.show($0) })
        playback.didStart = { [weak self] snapshot, artwork in
            guard snapshot.identity.hasPrefix("local:"), let userID = self?.auth.user?.id else { return }
            Task { @MainActor [weak self] in
                do { try await WebhookReporter().send(track: snapshot, artwork: artwork, userID: userID) }
                catch { self?.toasts.show(error) }
            }
        }
        auth.didChange = { [weak self] in self?.sessionChanged() }
        realtime.onOwnership = { [weak playback] in playback?.ownershipChanged($0) }
        realtime.onDisconnect = { [weak playback] in playback?.disconnected() }
        realtime.onConnect = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.playback.connected()
                do { try await self.friends.refresh() } catch { self.toasts.show(error) }
            }
        }
        realtime.onListening = { [weak self] event in
            self?.friends.listening(event)
            self?.auth.receiveListening(event)
        }
        realtime.onFriendship = { [weak self] name, event in
            Task { @MainActor in
                guard let self else { return }
                do {
                    try await self.friends.friendship(name, event: event)
                    if name == "friendRequest" { self.toasts.show("New friend request") }
                    else if name != "friendRemoved" { self.toasts.show("Friend list updated") }
                } catch { self.toasts.show(error) }
            }
        }
        realtime.validateSession = { [weak auth] in
            guard let auth else { return false }
            do { try await auth.refresh(); return auth.user != nil }
            catch let error as MapleError where error.status == 401 || error.status == 403 { await auth.invalidate(); return false }
            catch { return false }
        }
        AudioPlayerManager.shared.playbackReporter = playback
        AMPlayer.shared.playbackReporter = playback
        playback.snapshotProvider = {
            if AMPlayer.shared.initialized { return AMPlayer.shared.mapleSnapshot() }
            return AudioPlayerManager.shared.mapleSnapshot()
        }
    }
    func start() async { await auth.restore() }
    private func sessionChanged() {
        if signedInID != auth.user?.id {
            signedInID = auth.user?.id
            realtime.disconnect(); friends.clear()
            Task { await playback.stop() }
        }
        syncSocket()
        if auth.user != nil {
            Task { do { try await friends.refresh() } catch { toasts.show(error) } }
        }
    }
    func syncSocket() {
        if auth.user != nil, UserDefaults.standard.bool(forKey: "socketIO") { realtime.connect(cookies: http.sessionCookies) }
        else { realtime.disconnect() }
    }
}
