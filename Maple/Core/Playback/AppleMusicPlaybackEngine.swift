import Combine
import Foundation
import MusicKit
import MediaPlayer

/// Uses the system Music player so hand-off to Music.app remains intact.
@MainActor final class AppleMusicPlaybackEngine: PlaybackEngine {
    var onEvent: ((PlaybackEngineEvent) -> Void)?
    private let player = SystemMusicPlayer.shared
    private let resolver = AppleMusicTrackResolver<MusicKit.Track>(library: { id in
        var request = MusicLibraryRequest<MusicKit.Song>()
        request.filter(matching: \.id, equalTo: MusicItemID(id))
        return try await request.response().items.first.map { MusicKit.Track.song($0) }
    }, catalog: { id in
        let request = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, equalTo: MusicItemID(id))
        return try await request.response().items.first.map { MusicKit.Track.song($0) }
    })
    private(set) var unavailableEntryIDs: Set<UUID> = []
    private var observations: Set<AnyCancellable> = []
    private var configured = PlaybackQueue()
    private var occurrences: [String: UUID] = [:]
    private var generation = 0
    private var active = false
    private var preparing = false
    private var lastOccurrence: String?
    var position: Double { max(0, player.playbackTime.isFinite ? player.playbackTime : 0) }
    var duration: Double { currentItem?.duration ?? 0 }
    var rate: Double { let rate = Double(player.state.playbackRate); return rate > 0 ? rate : 1 }
    private var allowed: Bool {
        UserDefaults.standard.bool(forKey: "musicKit") && MusicAuthorization.currentStatus == .authorized
    }
    var isPlaying: Bool { allowed && player.state.playbackStatus == .playing }
    func externalPlayback() -> ExternalPlaybackState? {
        guard allowed, !active, !preparing, player.state.playbackStatus == .playing,
              let item = currentItem, let entry = player.queue.currentEntry else { return nil }
        return ExternalPlaybackState(item: item, occurrence: String(describing: entry.id))
    }
    private var currentItem: PlaybackItem? {
        guard let entry = player.queue.currentEntry else { return nil }
        switch entry.item {
        case .song(let song): return Self.item(.song(song))
        case .musicVideo, .none: return nil
        @unknown default: return nil
        }
    }
    init() {
        player.state.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.changed() }
        }.store(in: &observations)
        player.queue.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.changed() }
        }.store(in: &observations)
    }
    static func item(_ track: MusicKit.Track) -> PlaybackItem {
        var item = PlaybackItem(source: .appleMusic, id: track.id.rawValue, title: track.title,
            artist: track.artistName, album: track.albumTitle ?? "", duration: track.duration ?? 0,
            artworkURL: track.artwork?.url(width: 800, height: 800))
        // Apple catalog song IDs are decimal; library IDs use the separate i.* namespace.
        // For library songs, the public Apple Music URL can also supply a catalog equivalent.
        let catalogID = track.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first(where: { $0.name == "i" })?.value
        if UInt64(item.id) != nil {
            item.appleMusicIdentity = AppleMusicIdentity(catalogID: item.id)
        } else if item.id.hasPrefix("i.") {
            item.appleMusicIdentity = AppleMusicIdentity(libraryID: item.id, catalogID: catalogID)
        }
        return item
    }
    func register(_ values: [MusicKit.Track]) {
        for track in values { resolver.register(track, id: track.id.rawValue) }
    }
    func configure(_ queue: PlaybackQueue) async throws {
        configured = queue
        player.state.repeatMode = AppleMusicQueuePolicy.repeatMode(for: queue)
        // The controller already supplies shuffled order, including occurrence identity.
        player.state.shuffleMode = .off
    }
    func load(_ item: PlaybackItem) async throws {
        guard UserDefaults.standard.bool(forKey: "musicKit"), MusicAuthorization.currentStatus == .authorized else {
            throw MapleError(status: 0, message: "Enable Apple Music and allow library access in Settings.")
        }
        generation += 1
        let ticket = generation
        unavailableEntryIDs = []
        preparing = true
        defer { preparing = false }
        // Give Music.app the full contiguous Apple Music context so it can advance while Maple is suspended.
        let context = AppleMusicQueuePolicy.context(for: configured, fallback: item)
        guard let selectedID = configured.currentID ?? context.first?.id else { throw CancellationError() }
        let resolved = try await resolver.context(context, selected: selectedID)
        try Task.checkCancellation()
        guard generation == ticket else { throw CancellationError() }
        unavailableEntryIDs = resolved.unavailable
        var entries: [MusicKit.MusicPlayer.Queue.Entry] = []
        var selected: MusicKit.MusicPlayer.Queue.Entry?
        occurrences = [:]
        for (occurrence, track) in resolved.values {
            let entry = MusicKit.MusicPlayer.Queue.Entry(track)
            entries.append(entry); occurrences[String(describing: entry.id)] = occurrence.id
            if occurrence.id == selectedID { selected = entry }
        }
        player.queue = SystemMusicPlayer.Queue(entries, startingAt: selected ?? entries.first)
        try await player.prepareToPlay()
        try Task.checkCancellation()
        guard generation == ticket else { throw CancellationError() }
        active = true
        lastOccurrence = player.queue.currentEntry.map { String(describing: $0.id) }
    }
    func play() async throws { try await player.play() }
    func pause() { player.pause() }
    func stop() {
        generation += 1
        guard active else { return }
        active = false; player.stop(); lastOccurrence = nil; occurrences = [:]
    }
    /// Only an explicit Maple Stop may stop observed playback that Maple did not install.
    func stopExternalPlayback() {
        guard allowed else { return }
        player.stop(); lastOccurrence = nil; occurrences = [:]
    }
    func skipExternal(forward: Bool) async throws -> Bool {
        guard allowed, !active, player.queue.currentEntry != nil else { return false }
        if forward { try await player.skipToNextEntry() }
        else { try await player.skipToPreviousEntry() }
        changed()
        return true
    }
    func seek(to seconds: Double) async { player.playbackTime = seconds }
    private func changed() {
        guard allowed, !preparing else { return }
        guard active || externalPlayback() != nil else { onEvent?(.stateChanged); return }
        let occurrence = player.queue.currentEntry.map { String(describing: $0.id) }
        if occurrence != lastOccurrence, let item = currentItem, let occurrence {
            lastOccurrence = occurrence; onEvent?(.itemChanged(item, occurrence: occurrence, queueEntryID: occurrences[occurrence]))
        }
        if player.state.playbackStatus == .stopped {
            onEvent?(.ended)
        } else { onEvent?(.stateChanged) }
    }
}
