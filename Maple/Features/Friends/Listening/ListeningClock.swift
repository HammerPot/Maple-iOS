import Foundation

/// Extrapolates a playback position between server updates.
/// The server sends `position` already extrapolated to the moment it responded; this continues it at
/// `playbackRate` while playing, and holds it while paused. Results stay within 0…duration (or 0…24 h).
struct ListeningClock: Equatable, Sendable {
    let position: Double
    let duration: Double?
    let playbackRate: Double
    let playing: Bool
    let receivedAt: Date

    init(position: Double, duration: Double?, playbackRate: Double, playing: Bool, receivedAt: Date) {
        self.position = position; self.duration = duration; self.playbackRate = playbackRate
        self.playing = playing; self.receivedAt = receivedAt
    }
    init(_ current: CurrentPlayback, receivedAt: Date) {
        self.init(position: current.position, duration: current.duration, playbackRate: current.playbackRate,
                  playing: current.playing, receivedAt: receivedAt)
    }

    /// A usable duration: finite and positive, else nil.
    var knownDuration: Double? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        return min(duration, 86_400)
    }

    func elapsed(at now: Date) -> Double {
        let start = position.isFinite ? position : 0
        var value = start
        if playing {
            let rate = playbackRate.isFinite && playbackRate > 0 ? min(playbackRate, 16) : 1
            value += max(0, now.timeIntervalSince(receivedAt)) * rate
        }
        return min(max(value, 0), knownDuration ?? 86_400)
    }

    /// 0…1, or nil when the duration is unknown.
    func fraction(at now: Date) -> Double? {
        guard let total = knownDuration else { return nil }
        return elapsed(at: now) / total
    }

    func remaining(at now: Date) -> Double? {
        knownDuration.map { max(0, $0 - elapsed(at: now)) }
    }

    /// True once a playing track has run past its end without a new update (the server will soon say so).
    func hasEnded(at now: Date) -> Bool {
        guard let total = knownDuration else { return false }
        return playing && elapsed(at: now) >= total
    }
}

/// What to show for someone's listening.
enum ListeningStatus: Equatable {
    case current(CurrentPlayback)
    case lastPlayed(LastPlayed)
    /// Public, but nothing has been played.
    case nothing
    /// `listening` was null: the person keeps their listening private (or it is not visible to you).
    case hidden

    init(_ listening: Listening?) {
        guard let listening else { self = .hidden; return }
        if let current = listening.current { self = .current(current) }
        else if let last = listening.lastPlayed { self = .lastPlayed(last) }
        else { self = .nothing }
    }

    var artworkID: String? {
        switch self {
        case .current(let current): current.artwork
        case .lastPlayed(let last): last.artwork
        default: nil
        }
    }
}

extension CurrentPlayback {
    var byline: String { [artist, album].filter { !$0.isEmpty }.joined(separator: " — ") }
}
extension LastPlayed {
    var byline: String { [artist, album].filter { !$0.isEmpty }.joined(separator: " — ") }
}
