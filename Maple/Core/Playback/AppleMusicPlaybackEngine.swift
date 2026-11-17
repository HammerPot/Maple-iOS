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
    private var ownership = AppleMusicQueueOwnership()
    private var observedExternal = false
    private var generation = 0
    private var preparing = false
    private var lastOccurrence: String?
    private var resolvingTail: Task<Void, Never>?
    private var pendingTail: [PlaybackEntry] = []
    var position: Double { max(0, player.playbackTime.isFinite ? player.playbackTime : 0) }
    var duration: Double { currentItem?.duration ?? 0 }
    var rate: Double { let rate = Double(player.state.playbackRate); return rate > 0 ? rate : 1 }
    private var allowed: Bool {
        UserDefaults.standard.bool(forKey: "musicKit") && MusicAuthorization.currentStatus == .authorized
    }
    var isPlaying: Bool { allowed && player.state.playbackStatus == .playing }
    func externalPlayback() -> ExternalPlaybackState? {
        guard allowed, !ownership.ownsQueue, !preparing,
              player.state.playbackStatus != .stopped,
              player.state.playbackStatus == .playing || observedExternal,
              let item = currentItem, let entry = player.queue.currentEntry else { return nil }
        observedExternal = true
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
        player.state.repeatMode = AppleMusicQueuePolicy.repeatMode(for: queue, installedEntries: Set(ownership.entries.values))
        // The controller already supplies shuffled order, including occurrence identity.
        player.state.shuffleMode = .off
    }
    func load(_ item: PlaybackItem) async throws {
        guard UserDefaults.standard.bool(forKey: "musicKit"), MusicAuthorization.currentStatus == .authorized else {
            throw MapleError(status: 0, message: "Enable Apple Music and allow library access in Settings.")
        }
        generation += 1; resolvingTail?.cancel(); resolvingTail = nil; pendingTail = []
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
        pendingTail = resolved.remaining
        var entries: [MusicKit.MusicPlayer.Queue.Entry] = []
        var selected: MusicKit.MusicPlayer.Queue.Entry?
        var occurrences: [String: UUID] = [:]
        for (occurrence, track) in resolved.values {
            let entry = MusicKit.MusicPlayer.Queue.Entry(track)
            entries.append(entry); occurrences[String(describing: entry.id)] = occurrence.id
            if occurrence.id == selectedID { selected = entry }
        }
        ownership.install(occurrences); observedExternal = false
        player.queue = SystemMusicPlayer.Queue(entries, startingAt: selected ?? entries.first)
        try await player.prepareToPlay()
        try Task.checkCancellation()
        guard generation == ticket else { throw CancellationError() }
        lastOccurrence = player.queue.currentEntry.map { String(describing: $0.id) }
        player.state.repeatMode = AppleMusicQueuePolicy.repeatMode(for: configured, installedEntries: Set(ownership.entries.values))
    }
    func play() async throws {
        try await player.play()
        extendQueueInBackground()
    }
    /// Bounded batches start only after Play returns. A takeover/stop cancels and fences insertion.
    private func extendQueueInBackground() {
        guard resolvingTail == nil, !pendingTail.isEmpty else { return }
        let ticket = generation, remaining = pendingTail
        pendingTail = []
        resolvingTail = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == ticket { self.resolvingTail = nil } }
            for offset in stride(from: 0, to: remaining.count, by: 10) {
                do {
                    let batch = Array(remaining.dropFirst(offset).prefix(10))
                    let result = try await self.resolver.resolveBatch(batch)
                    try Task.checkCancellation()
                    guard self.generation == ticket, self.ownership.ownsQueue else { return }
                    let values = result.values.map { ($0.0, MusicKit.MusicPlayer.Queue.Entry($0.1)) }
                    let entries = values.map(\.1)
                    // Register before awaiting insertion so its notifications recognize Maple entries.
                    self.ownership.append(Dictionary(uniqueKeysWithValues: values.map { (String(describing: $0.1.id), $0.0.id) }))
                    do {
                        if !entries.isEmpty { try await self.player.queue.insert(entries, position: .tail) }
                    } catch {
                        if self.generation == ticket {
                            self.ownership.remove(Set(entries.map { String(describing: $0.id) }))
                        }
                        throw error
                    }
                    guard self.generation == ticket, self.ownership.ownsQueue else { return }
                    if !result.unavailable.isEmpty {
                        self.unavailableEntryIDs.formUnion(result.unavailable)
                        self.configured.remove(result.unavailable)
                        self.onEvent?(.unavailableEntries(result.unavailable))
                    }
                    self.player.state.repeatMode = AppleMusicQueuePolicy.repeatMode(for: self.configured, installedEntries: Set(self.ownership.entries.values))
                } catch { return } // Transient failures leave Maple's entries intact for the next explicit load.
            }
        }
    }
    func pause() { player.pause() }
    func stop() {
        generation += 1; resolvingTail?.cancel(); resolvingTail = nil; pendingTail = []
        guard ownership.ownsQueue else { return }
        ownership.relinquish(); player.stop(); lastOccurrence = nil
    }
    /// Only an explicit Maple Stop may stop observed playback that Maple did not install.
    func stopExternalPlayback() {
        guard allowed else { return }
        generation += 1; resolvingTail?.cancel(); resolvingTail = nil; pendingTail = []
        ownership.relinquish(); observedExternal = false
        player.stop(); lastOccurrence = nil
    }
    func skipExternal(forward: Bool) async throws -> Bool {
        guard allowed, !ownership.ownsQueue, player.queue.currentEntry != nil else { return false }
        if forward { try await player.skipToNextEntry() }
        else { try await player.skipToPreviousEntry() }
        changed()
        return true
    }
    func seek(to seconds: Double) async { player.playbackTime = seconds }
    private func changed() {
        guard allowed, !preparing else { return }
        let occurrence = player.queue.currentEntry.map { String(describing: $0.id) }
        let wasOwned = ownership.ownsQueue
        let result = ownership.observe(occurrence: occurrence,
            playing: player.state.playbackStatus == .playing, stopped: player.state.playbackStatus == .stopped)
        if wasOwned && !ownership.ownsQueue {
            generation += 1; resolvingTail?.cancel(); resolvingTail = nil; pendingTail = []
        }
        if player.state.playbackStatus == .stopped { observedExternal = false }
        if occurrence != lastOccurrence, let item = currentItem, let occurrence {
            lastOccurrence = occurrence
            onEvent?(.itemChanged(item, occurrence: occurrence, queueEntryID: result.entry))
        }
        if result.ended { onEvent?(.ended) }
        else { onEvent?(.stateChanged) }
    }
}
