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
    let toasts: ToastCenter
    private let webhook = WebhookReporter()
    /// Audio and artwork stay in Documents (visible in the Files app, as before); the catalog
    /// lives privately in Application Support.
    let library = LibraryStore(root: URL.documentsDirectory,
                               catalogDirectory: URL.applicationSupportDirectory.appendingPathComponent("Library", isDirectory: true))
    private var signedInID: String?

    init() {
        UserDefaults.standard.register(defaults: ["socketIO": true])
        let toasts = ToastCenter()
        self.toasts = toasts
        #if DEBUG
        let configuration = AccountVerificationSupport.configuration
        #else
        let configuration = URLSessionConfiguration.ephemeral
        #endif
        let http = MapleHTTP(cookies: MapleHTTP.persistentCookies(onSaveFailure: { error in
            Task { @MainActor in toasts.show(error) }
        }), configuration: configuration)
        self.http = http
        let api = MapleAPI(http: http)
        self.api = api
        auth = AuthSessionModel(api: api)
        friends = FriendsModel(api: api)
        let realtime = MapleRealtime()
        self.realtime = realtime
        playback = PlaybackReporter(transport: realtime, upload: { try await api.setAlbumArt($0, playbackId: $1) }, reportError: { toasts.show($0) })
        playback.didStart = { [weak self] snapshot, artwork in
            guard snapshot.identity.hasPrefix("local:"), let userID = self?.auth.user?.id else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await self.webhook.send(track: snapshot, artwork: artwork, userID: userID) }
                catch { self.toasts.show(error) }
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
        friends.announce = { [weak self] notice in
            guard let self else { return }
            let accept = notice.acceptRequestID.map { id in
                ToastCenter.Action(title: "Accept") { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        do { try await self.friends.accept(id: id) } catch { self.toasts.show(error) }
                    }
                }
            }
            self.toasts.show(notice.message, action: accept)
        }
        realtime.onFriendship = { [weak self] name, event in
            Task { @MainActor in
                guard let self else { return }
                // FriendsModel announces each event (with Accept for incoming requests) once the lists are updated.
                do { try await self.friends.friendship(name, event: event) } catch { self.toasts.show(error) }
            }
        }
        realtime.validateSession = { [weak auth] in
            guard let auth else { return .invalid }
            do { try await auth.refresh(); return auth.user != nil ? .valid : .invalid }
            catch let error as MapleError where error.status == 401 { await auth.invalidate(); return .invalid }
            catch { return .unreachable }
        }
        AudioPlayerManager.shared.libraryStore = library
        library.willDeleteTracks = { ids in AudioPlayerManager.shared.removeLibraryTracks(ids) }
        AudioPlayerManager.shared.playbackReporter = playback
        AMPlayer.shared.playbackReporter = playback
        playback.snapshotProvider = {
            if AMPlayer.shared.initialized { return AMPlayer.shared.mapleSnapshot() }
            return AudioPlayerManager.shared.mapleSnapshot()
        }
    }
    func start() async {
        async let restored: Void = auth.restore()
        await library.load()
        library.scanForNewFiles(silently: true)
        await restored
    }
    func sceneBecameActive() async {
        await auth.sceneBecameActive()
        realtime.sceneBecameActive()
        await playback.sceneBecameActive()
    }
    private func sessionChanged() {
        if signedInID != auth.user?.id {
            signedInID = auth.user?.id
            realtime.disconnect(); friends.clear()
            playback.resetSession()
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
