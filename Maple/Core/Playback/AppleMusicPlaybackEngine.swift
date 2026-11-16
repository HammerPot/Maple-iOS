import Combine
import Foundation
import MusicKit
import MediaPlayer

/// Uses the system Music player so hand-off to Music.app remains intact.
@MainActor final class AppleMusicPlaybackEngine: PlaybackEngine {
    var onEvent: ((PlaybackEngineEvent) -> Void)?
    private let player = SystemMusicPlayer.shared
    private var tracks: [String: MusicKit.Track] = [:]
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
    var isPlaying: Bool { active && player.state.playbackStatus == .playing }
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
        PlaybackItem(source: .appleMusic, id: track.id.rawValue, title: track.title,
            artist: track.artistName, album: track.albumTitle ?? "", duration: track.duration ?? 0,
            artworkURL: track.artwork?.url(width: 800, height: 800))
    }
    func register(_ values: [MusicKit.Track]) {
        for track in values { tracks[track.id.rawValue] = track }
    }
    func configure(_ queue: PlaybackQueue) async throws {
        configured = queue
        player.state.repeatMode = queue.repeatMode == .one ? .one : (queue.repeatMode == .all ? .all : MusicKit.MusicPlayer.RepeatMode.none)
        // The controller already supplies shuffled order, including occurrence identity.
        player.state.shuffleMode = .off
    }
    private func resolve(_ item: PlaybackItem) async throws -> MusicKit.Track {
        if let track = tracks[item.id] { return track }
        var request = MusicLibraryRequest<MusicKit.Song>()
        request.filter(matching: \.id, equalTo: MusicItemID(item.id))
        if let song = try await request.response().items.first {
            let track = MusicKit.Track.song(song); tracks[item.id] = track; return track
        }
        throw MapleError(status: 0, message: "This Apple Music track is no longer available in your library.")
    }
    func load(_ item: PlaybackItem) async throws {
        guard UserDefaults.standard.bool(forKey: "musicKit"), MusicAuthorization.currentStatus == .authorized else {
            throw MapleError(status: 0, message: "Enable Apple Music and allow library access in Settings.")
        }
        generation += 1
        let ticket = generation
        preparing = true
        defer { preparing = false }
        // Give Music.app the full contiguous Apple Music context so it can advance while Maple is suspended.
        let current = configured.index ?? 0
        var lower = current, upper = current
        while lower > 0 && configured.entries[lower - 1].item.source == .appleMusic { lower -= 1 }
        while upper + 1 < configured.entries.count && configured.entries[upper + 1].item.source == .appleMusic { upper += 1 }
        let context = configured.entries.indices.contains(current) ? Array(configured.entries[lower...upper]) : [PlaybackEntry(item: item)]
        var entries: [MusicKit.MusicPlayer.Queue.Entry] = []
        var selected: MusicKit.MusicPlayer.Queue.Entry?
        occurrences = [:]
        for occurrence in context {
            let track = try await resolve(occurrence.item)
            try Task.checkCancellation()
            guard generation == ticket else { throw CancellationError() }
            let entry = MusicKit.MusicPlayer.Queue.Entry(track)
            entries.append(entry); occurrences[String(describing: entry.id)] = occurrence.id
            if occurrence.id == configured.currentID { selected = entry }
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
        active = false; player.stop(); lastOccurrence = nil
    }
    func seek(to seconds: Double) async { player.playbackTime = seconds }
    private func changed() {
        guard active, !preparing else { return }
        let occurrence = player.queue.currentEntry.map { String(describing: $0.id) }
        if occurrence != lastOccurrence, let item = currentItem, let occurrence {
            lastOccurrence = occurrence; onEvent?(.itemChanged(item, occurrence: occurrence, queueEntryID: occurrences[occurrence]))
        }
        if player.state.playbackStatus == .stopped {
            onEvent?(.ended)
        } else { onEvent?(.stateChanged) }
    }
}
