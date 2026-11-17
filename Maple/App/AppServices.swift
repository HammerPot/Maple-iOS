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
    let player: PlaybackController
    let music: AppleMusicService
    let settings: SettingsModel
    private let webhook: WebhookReporter
    private let systemControls = PlaybackSystemControls()
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
        let credentials = WebhookCredentials()
        settings = SettingsModel(credentials: credentials)
        webhook = WebhookReporter(configuredURL: {
            return DiscordWebhookURL.configuredValue((try? await credentials.read()) ?? "")
        })
        auth = AuthSessionModel(api: api)
        friends = FriendsModel(api: api)
        let realtime = MapleRealtime()
        self.realtime = realtime
        realtime.cookieProvider = { http.sessionCookies }
        playback = PlaybackReporter(transport: realtime, upload: { try await api.setAlbumArt($0, playbackId: $1) }, reportError: { toasts.show($0) })
        let apple = AppleMusicPlaybackEngine()
        music = AppleMusicService(engine: apple)
        let player = PlaybackController(local: LocalPlaybackEngine(), apple: apple, reporter: playback,
            persistence: PlaybackPersistence(url: URL.applicationSupportDirectory.appendingPathComponent("Playback/queue.json")))
        self.player = player
        playback.didStart = { [weak self] snapshot, artwork in
            guard snapshot.identity.hasPrefix("local:"), let userID = self?.auth.user?.id else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await self.webhook.send(track: snapshot, artwork: artwork, userID: userID) }
                catch { self.toasts.show(error) }
            }
        }
        auth.didChange = { [weak self] in self?.sessionChanged() }
        http.sessionChanged.set { [weak self] in await self?.syncSocket() }
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
        player.onError = { [weak toasts] in toasts?.show($0) }
        let library = library
        player.recordStart = { [weak library] in library?.recordStart($0) }
        player.recordListening = { [weak library] in library?.recordListening($0, seconds: $1) }
        player.recordEnd = { [weak library] in library?.recordEnd($0, completed: $1) }
        library.willDeleteTracks = { [weak player] in player?.removeLibraryTracks($0) }
        LibraryPlayback.start = { [weak player, weak library] tracks, id, shuffle in
            guard let player, let library else { return }
            let items = tracks.map { PlaybackItem(track: $0, library: library) }
            let index = tracks.firstIndex { $0.id == id }
            Task { await player.start(items, startingAt: index, shuffle: shuffle) }
        }
        LibraryPlayback.add = { [weak player, weak library] tracks, next in
            guard let player, let library else { return }
            player.enqueue(tracks.map { PlaybackItem(track: $0, library: library) }, next: next)
        }
        playback.snapshotProvider = { [weak player] in player?.snapshot }
        playback.artworkProvider = { [weak player] identity in await player?.artworkForClaim(identity: identity) }
        systemControls.bind(player)
    }
    func start() async {
        async let restored: Void = auth.restore()
        do { try await settings.load() } catch { toasts.show(error) }
        await library.load()
        await player.restore { [library] id in library.track(id).map { PlaybackItem(track: $0, library: library) } }
        await music.refreshAuthorization()
        library.scanForNewFiles(silently: true)
        await restored
    }
    func sceneBecameActive() async {
        player.refresh()
        await music.refreshAuthorization()
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
