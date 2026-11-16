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
    private var active = false
    private var preparing = false
    private var lastOccurrence: String?
    var position: Double { max(0, player.playbackTime.isFinite ? player.playbackTime : 0) }
    var duration: Double { currentItem?.duration ?? 0 }
    var rate: Double { let rate = Double(MPMusicPlayerController.systemMusicPlayer.currentPlaybackRate); return rate > 0 ? rate : 1 }
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
    func load(_ item: PlaybackItem) async throws {
        guard UserDefaults.standard.bool(forKey: "musicKit"), MusicAuthorization.currentStatus == .authorized else {
            throw MapleError(status: 0, message: "Enable Apple Music and allow library access in Settings.")
        }
        preparing = true
        defer { preparing = false }
        var track = tracks[item.id]
        if track == nil {
            var request = MusicLibraryRequest<MusicKit.Song>()
            request.filter(matching: \.id, equalTo: MusicItemID(item.id))
            if let song = try await request.response().items.first { track = .song(song) }
        }
        guard let track else { throw MapleError(status: 0, message: "This Apple Music track is no longer available in your library.") }
        try Task.checkCancellation()
        player.queue = SystemMusicPlayer.Queue(for: [track])
        try await player.prepareToPlay()
        try Task.checkCancellation()
        active = true
        lastOccurrence = player.queue.currentEntry.map { String(describing: $0.id) }
    }
    func play() async throws { try await player.play() }
    func pause() { player.pause() }
    func stop() {
        guard active else { return }
        active = false; player.stop(); lastOccurrence = nil
    }
    func seek(to seconds: Double) async { player.playbackTime = seconds }
    private func changed() {
        guard active, !preparing else { return }
        let occurrence = player.queue.currentEntry.map { String(describing: $0.id) }
        if occurrence != lastOccurrence, let item = currentItem, let occurrence {
            lastOccurrence = occurrence; onEvent?(.itemChanged(item, occurrence: occurrence))
        }
        if player.state.playbackStatus == .stopped, position < 0.5 {
            onEvent?(.ended)
        } else { onEvent?(.stateChanged) }
    }
}
