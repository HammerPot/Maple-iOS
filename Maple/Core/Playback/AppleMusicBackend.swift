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
    private var preparingInstalledQueue = false
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
                                    reportedStatus: String(describing: player.state.playbackStatus))
    }
    func register(_ values: [MusicKit.Track]) { for value in values { resolver.register(value, id: value.id.rawValue) } }
    func prepare(_ context: [PlaybackEntry], selected: UUID, progress: (Double) -> Void) async throws -> AppleMusicInstallation {
        preparationGeneration += 1
        let ticket = preparationGeneration
        defer { if ticket == preparationGeneration { preparingInstalledQueue = false } }
        let resolved = try await resolver.context(context, selected: selected, progress: progress)
        var entries: [MusicKit.MusicPlayer.Queue.Entry] = [], installed: [AppleMusicInstalledEntry] = []
        var start: MusicKit.MusicPlayer.Queue.Entry?
        for (occurrence, track) in resolved.values {
            let entry = MusicKit.MusicPlayer.Queue.Entry(track)
            entries.append(entry)
            installed.append(AppleMusicInstalledEntry(entry: occurrence,
                identities: occurrence.item.musicIdentityIDs.union(Self.item(track).musicIdentityIDs), systemID: String(describing: entry.id)))
            if occurrence.id == selected { start = entry }
        }
        guard let start else { throw AppleMusicResolutionError.notFound }
        try Task.checkCancellation()
        guard ticket == preparationGeneration else { throw CancellationError() }
        AppleMusicDiagnostics.logger.info("install count=\(installed.count, privacy: .public) entries=\(AppleMusicDiagnostics.installation(installed), privacy: .public)")
        player.queue = SystemMusicPlayer.Queue(entries, startingAt: start)
        preparingInstalledQueue = true
        do {
            try await player.prepareToPlay()
            try Task.checkCancellation()
            guard ticket == preparationGeneration else { throw CancellationError() }
        } catch {
            if ticket == preparationGeneration {
                AppleMusicDiagnostics.logger.info("stop classification=unknown reason=prepare failed or cancelled after assignment")
                player.stop()
            }
            throw error
        }
        return AppleMusicInstallation(entries: installed, unavailable: resolved.unavailable)
    }
    func cancelPreparation() {
        preparationGeneration += 1
        if preparingInstalledQueue {
            AppleMusicDiagnostics.logger.info("stop classification=user stop reason=cancel superseded preparation after assignment")
            player.stop(); preparingInstalledQueue = false
        }
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
    static func item(_ track: MusicKit.Track) -> PlaybackItem {
        var item = PlaybackItem(source: .appleMusic, id: track.id.rawValue, title: track.title,
            artist: track.artistName, album: track.albumTitle ?? "", duration: track.duration ?? 0,
            artworkURL: track.artwork?.url(width: 800, height: 800))
        let catalogID = track.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first(where: { $0.name == "i" })?.value
        if UInt64(item.id) != nil { item.appleMusicIdentity = AppleMusicIdentity(catalogID: item.id) }
        else if item.id.hasPrefix("i.") { item.appleMusicIdentity = AppleMusicIdentity(libraryID: item.id, catalogID: catalogID) }
        return item
    }
}
