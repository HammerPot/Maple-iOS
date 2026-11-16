import Foundation
import Observation

enum PlaybackEngineEvent {
    case stateChanged
    case ended
    case itemChanged(PlaybackItem, occurrence: String, queueEntryID: UUID? = nil)
    case failed(Error)
}

struct ExternalPlaybackState {
    let item: PlaybackItem
    let occurrence: String
}

@MainActor protocol PlaybackEngine: AnyObject {
    var onEvent: ((PlaybackEngineEvent) -> Void)? { get set }
    var position: Double { get }
    var duration: Double { get }
    var rate: Double { get }
    var isPlaying: Bool { get }
    func configure(_ queue: PlaybackQueue) async throws
    func externalPlayback() -> ExternalPlaybackState?
    func load(_ item: PlaybackItem) async throws
    func play() async throws
    func pause()
    func stop()
    func stopExternalPlayback()
    func seek(to seconds: Double) async
}

extension PlaybackEngine {
    func configure(_ queue: PlaybackQueue) async throws {}
    func externalPlayback() -> ExternalPlaybackState? { nil }
    func stopExternalPlayback() {}
}

/// Only scrubbers/lyrics observe this clock. Metadata, mini-player and the tab shell do not.
@MainActor @Observable final class PlaybackPosition {
    var seconds: Double = 0
}

@MainActor protocol PlaybackReporting: AnyObject {
    func update(_ value: TrackSnapshot, artwork: Data?, force: Bool) async
    func playbackStarted() async
    func stop() async
}
extension PlaybackReporter: PlaybackReporting {}

struct PlaybackCheckpoint: Codable, Sendable {
    var queue: PlaybackQueue
    var position: Double
}

actor PlaybackPersistence {
    let url: URL
    init(url: URL) { self.url = url }
    func load() throws -> PlaybackCheckpoint? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(PlaybackCheckpoint.self, from: Data(contentsOf: url))
    }
    func save(_ checkpoint: PlaybackCheckpoint) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(checkpoint).write(to: url, options: .atomic)
    }
}
