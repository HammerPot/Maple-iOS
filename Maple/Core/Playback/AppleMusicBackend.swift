import Combine
import Foundation
import MusicKit
import OSLog

struct AppleMusicPlayerState {
    enum Status { case playing, paused, stopped }
    var item: PlaybackItem?
    var occurrence: String?
    var status: Status = .stopped
    var position = 0.0
    var rate = 1.0
    var reportedStatus: String? = nil
    var reportedModes: String? = nil
}
struct AppleMusicInstalledEntry {
    var entry: PlaybackEntry
    var identities: Set<String>
    var systemID: String?
}
struct AppleMusicInstallation {
    var entries: [AppleMusicInstalledEntry]
    var unavailable: Set<UUID> = []
}

/// The framework boundary. Engine and controller tests use the same session logic with a fake here.
@MainActor protocol AppleMusicBackend: AnyObject {
    var onChange: (() -> Void)? { get set }
    var state: AppleMusicPlayerState { get }
    func prepare(_ entries: [PlaybackEntry], selected: UUID, progress: (Double) -> Void) async throws -> AppleMusicInstallation
    func append(_ entries: [PlaybackEntry], after current: PlaybackEntry) async throws -> AppleMusicInstallation
    func cancelPreparation()
    func configure(repeatMode: PlaybackRepeat)
    func play() async throws
    func pause()
    func stop()
    func seek(to seconds: Double)
    func skip(forward: Bool) async throws
}

@MainActor final class SystemMusicBackend: AppleMusicBackend {
    var onChange: (() -> Void)?
    private let player = SystemMusicPlayer.shared
    private var preparationGeneration = 0
    private let preparation = AppleMusicPreparation()
    private var observations: Set<AnyCancellable> = []
    private let resolver = AppleMusicTrackResolver<MusicKit.Track>(library: { (ids: [String]) async throws -> [String: MusicKit.Track] in
        var request = MusicLibraryRequest<MusicKit.Song>()
        request.filter(matching: \.id, memberOf: ids.map { MusicItemID($0) })
        request.limit = ids.count
        return Dictionary(uniqueKeysWithValues: try await request.response().items.map { ($0.id.rawValue, MusicKit.Track.song($0)) })
    }, catalog: { (ids: [String]) async throws -> [String: MusicKit.Track] in
        var request = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, memberOf: ids.map { MusicItemID($0) })
        request.limit = ids.count
        return Dictionary(uniqueKeysWithValues: try await request.response().items.map { ($0.id.rawValue, MusicKit.Track.song($0)) })
    }, identities: { SystemMusicBackend.item($0).musicIdentityIDs })
    init() {
        player.state.objectWillChange.sink { [weak self] _ in Task { @MainActor in self?.onChange?() } }.store(in: &observations)
        player.queue.objectWillChange.sink { [weak self] _ in Task { @MainActor in self?.onChange?() } }.store(in: &observations)
    }
    var state: AppleMusicPlayerState {
        let entry = player.queue.currentEntry
        let song: PlaybackItem?
        if case .song(let value) = entry?.item { song = Self.item(.song(value)) } else { song = nil }
        let status: AppleMusicPlayerState.Status = player.state.playbackStatus == .playing ? .playing : (player.state.playbackStatus == .stopped ? .stopped : .paused)
        let time = player.playbackTime, rate = Double(player.state.playbackRate)
        return AppleMusicPlayerState(item: song, occurrence: entry.map { String(describing: $0.id) }, status: status,
                                    position: time.isFinite ? max(0, time) : 0, rate: rate > 0 ? rate : 1,
                                    reportedStatus: String(describing: player.state.playbackStatus),
                                    reportedModes: "repeat=\(String(describing: player.state.repeatMode)) shuffle=\(String(describing: player.state.shuffleMode))")
    }
    func register(_ values: [MusicKit.Track]) { for value in values { resolver.register(value, id: value.id.rawValue) } }
    func prepare(_ context: [PlaybackEntry], selected: UUID, progress: (Double) -> Void) async throws -> AppleMusicInstallation {
        preparationGeneration += 1
        let ticket = preparationGeneration
        let resolved = try await resolver.context(context, selected: selected, progress: progress)
        var entries: [MusicKit.MusicPlayer.Queue.Entry] = [], installed: [AppleMusicInstalledEntry] = []
        var start: MusicKit.MusicPlayer.Queue.Entry?
        for (occurrence, track) in try Self.playableTracks(resolved.values, selected: selected) {
            let entry = MusicKit.MusicPlayer.Queue.Entry(track)
            entries.append(entry)
            installed.append(AppleMusicInstalledEntry(entry: occurrence,
                identities: occurrence.item.musicIdentityIDs.union(Self.item(track).musicIdentityIDs), systemID: String(describing: entry.id)))
            if occurrence.id == selected { start = entry }
        }
        guard let start else { throw AppleMusicResolutionError.notFound }
        try Task.checkCancellation()
        guard ticket == preparationGeneration else { throw CancellationError() }
        try await preparation.run { [self, entries, start, installed] in
            try Task.checkCancellation()
            guard ticket == preparationGeneration else { throw CancellationError() }
            AppleMusicDiagnostics.logger.info("install count=\(installed.count, privacy: .public) entries=\(AppleMusicDiagnostics.installation(installed), privacy: .public)")
            player.queue = SystemMusicPlayer.Queue(entries, startingAt: start)
            let began = Date()
            do {
                try await player.prepareToPlay()
                AppleMusicDiagnostics.logger.info("prepare count=\(entries.count, privacy: .public) elapsed=\(Date().timeIntervalSince(began), privacy: .public) result=success")
            } catch {
                AppleMusicDiagnostics.logger.info("prepare count=\(entries.count, privacy: .public) elapsed=\(Date().timeIntervalSince(began), privacy: .public) errorDomain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code, privacy: .public)")
                throw error
            }
        }
        try Task.checkCancellation()
        guard ticket == preparationGeneration else { throw CancellationError() }
        return AppleMusicInstallation(entries: installed, unavailable: resolved.unavailable)
    }
    func append(_ context: [PlaybackEntry], after current: PlaybackEntry) async throws -> AppleMusicInstallation {
        let ticket = preparationGeneration
        // The loaded current item anchors resolution; a missing upcoming item cannot fail it.
        let resolved = try await resolver.context([current] + context, selected: current.id)
        let values = try Self.playableTracks(resolved.values, selected: current.id).filter { $0.0.id != current.id }
        let native = values.map { MusicKit.MusicPlayer.Queue.Entry($0.1) }
        let installed = zip(values, native).map { value, entry in
            AppleMusicInstalledEntry(entry: value.0, identities: value.0.item.musicIdentityIDs.union(Self.item(value.1).musicIdentityIDs), systemID: String(describing: entry.id))
        }
        try await preparation.run { [self] in
            try Task.checkCancellation()
            guard ticket == preparationGeneration else { throw CancellationError() }
            guard !native.isEmpty else { return }
            let began = Date()
            try await player.queue.insert(native, position: .tail)
            AppleMusicDiagnostics.logger.info("append count=\(native.count, privacy: .public) elapsed=\(Date().timeIntervalSince(began), privacy: .public) entries=\(AppleMusicDiagnostics.installation(installed), privacy: .public)")
        }
        try Task.checkCancellation()
        guard ticket == preparationGeneration else { throw CancellationError() }
        return AppleMusicInstallation(entries: installed, unavailable: resolved.unavailable)
    }
    func cancelPreparation() {
        preparationGeneration += 1
        // Preparation never starts audio. Do not send a late native stop into the next install.
    }
    func configure(repeatMode: PlaybackRepeat) {
        player.state.shuffleMode = .off
        switch repeatMode { case .off: player.state.repeatMode = MusicKit.MusicPlayer.RepeatMode.none; case .one: player.state.repeatMode = .one; case .all: player.state.repeatMode = .all }
    }
    func play() async throws { try await player.play() }
    func pause() { player.pause() }
    func stop() { player.stop() }
    func seek(to seconds: Double) { player.playbackTime = seconds }
    func skip(forward: Bool) async throws {
        if forward { try await player.skipToNextEntry() } else { try await player.skipToPreviousEntry() }
    }
    static func playableTracks(_ values: [(PlaybackEntry, MusicKit.Track)], selected: UUID) throws -> [(PlaybackEntry, MusicKit.Track)] {
        try values.filter { entry, track in
            guard track.playParameters != nil else {
                AppleMusicDiagnostics.logger.info("resolution deferred song=\(track.id.rawValue, privacy: .public) reason=no playback parameters; keep Maple entry")
                if entry.id == selected { throw AppleMusicResolutionError.notPlayable }
                return false
            }
            return true
        }
    }
    static func item(_ track: MusicKit.Track) -> PlaybackItem {
        var item = PlaybackItem(source: .appleMusic, id: track.id.rawValue, title: track.title,
            artist: track.artistName, album: track.albumTitle ?? "", duration: track.duration ?? 0,
            artworkURL: track.artwork?.url(width: 800, height: 800))
        let parameters = track.playParameters.flatMap { try? JSONEncoder().encode($0) }
        let catalogID = AppleMusicIdentity.catalogID(url: track.url, playParameters: parameters)
        if UInt64(item.id) != nil { item.appleMusicIdentity = AppleMusicIdentity(catalogID: item.id) }
        else if item.id.hasPrefix("i.") { item.appleMusicIdentity = AppleMusicIdentity(libraryID: item.id, catalogID: catalogID) }
        return item
    }
}

extension AppleMusicIdentity {
    /// Library URLs may be absent. The Codable playback payload carries the catalog equivalent
    /// used by SystemMusicPlayer, whose current Song and Entry IDs are rewritten on hardware.
    static func catalogID(url: URL?, playParameters: Data?) -> String? {
        struct Parameters: Decodable { var catalogId: String? }
        if let playParameters, let id = (try? JSONDecoder().decode(Parameters.self, from: playParameters))?.catalogId,
           UInt64(id) != nil { return id }
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if let id = components.queryItems?.first(where: { $0.name == "i" })?.value, UInt64(id) != nil { return id }
        if components.path.contains("/song/"), UInt64(url.lastPathComponent) != nil { return url.lastPathComponent }
        return nil
    }
}
