import Foundation

struct MaplePlaybackSnapshot {
    let trackID: String
    let source: String
    let title: String
    let artist: String
    let album: String
    let playing: Bool
    let position: TimeInterval
    let duration: TimeInterval
    var playbackRate: Double = 1

    var trackKey: String { source + ":" + trackID }

    func payload(discord: Bool) -> [String: Any] {
        let position = position.isFinite ? max(0, position) : 0
        let duration = duration.isFinite && duration > 0 ? duration : nil
        var result: [String: Any] = [
            "title": title.isEmpty ? "Unknown Song" : title,
            "artist": artist.isEmpty ? "Unknown Artist" : artist,
            "album": album.isEmpty ? "Unknown Album" : album,
            "playing": playing && !trackID.isEmpty && (duration.map { position < $0 } ?? true),
            "position": position, "discord": discord,
            "playbackRate": playbackRate.isFinite && playbackRate > 0 ? playbackRate : 1.0
        ]
        if let duration { result["duration"] = duration }
        return result
    }
}
