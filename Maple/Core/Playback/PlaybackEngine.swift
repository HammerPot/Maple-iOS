import Foundation
import Observation

enum PlaybackEngineEvent {
    case loadingProgress(Double)
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
    var unavailableEntryIDs: Set<UUID> { get }
    func configure(_ queue: PlaybackQueue) async throws
    func refresh()
    func externalPlayback() -> ExternalPlaybackState?
    func load(_ item: PlaybackItem) async throws
    func play() async throws
    func pause()
    func stop()
    func stopExternalPlayback()
    func skipExternal(forward: Bool) async throws -> Bool
    func seek(to seconds: Double) async
}

extension PlaybackEngine {
    var unavailableEntryIDs: Set<UUID> { [] }
    func refresh() {}
    func configure(_ queue: PlaybackQueue) async throws {}
    func externalPlayback() -> ExternalPlaybackState? { nil }
    func stopExternalPlayback() {}
    func skipExternal(forward: Bool) async throws -> Bool { false }
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
    var positionKey: UUID? = nil
}

actor PlaybackPersistence {
    let url: URL
    init(url: URL) { self.url = url }
    func load() throws -> PlaybackCheckpoint? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var value = try JSONDecoder().decode(PlaybackCheckpoint.self, from: Data(contentsOf: url))
        if let key = value.positionKey, let data = try? Data(contentsOf: positionURL), data.count == 44,
           String(data: data.prefix(36), encoding: .utf8) == key.uuidString {
            let bits = data.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let seconds = Double(bitPattern: bits)
            if seconds.isFinite { value.position = max(0, seconds) }
        }
        return value
    }
    var positionURL: URL { url.appendingPathExtension("position") }
    /// A fixed 44 bytes, independent of queue size. The key prevents stale positions crossing saves.
    func savePosition(_ seconds: Double, key: UUID) throws {
        guard seconds.isFinite else { return }
        var data = Data(key.uuidString.utf8)
        var bits = max(0, seconds).bitPattern.bigEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        try data.write(to: positionURL, options: .atomic)
    }
    func save(_ checkpoint: PlaybackCheckpoint) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(checkpoint).write(to: url, options: .atomic)
    }
}
