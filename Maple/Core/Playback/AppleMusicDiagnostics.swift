import Foundation
import OSLog

/// Only Music identifiers and playback state. Never pass account data, artwork URLs or credentials.
enum AppleMusicDiagnostics {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.hammerpot.Maple-iOS", category: "AppleMusic")
    // MusicKit exposes a raw Song.ID, not its namespace. This is the existing conversion
    // inference; compare it with the authoritative library-browse source before trusting it.
    static func kind(_ item: PlaybackItem?) -> String {
        guard let item else { return "unknown" }
        if item.appleMusicIdentity?.libraryID != nil { return "library" }
        if item.appleMusicIdentity?.catalogID != nil { return "catalog" }
        return "unknown"
    }
    static func ids(_ values: [String]) -> String {
        values.map { "\($0)(\(UInt64($0) == nil ? "nonnumeric" : "numeric"))" }.joined(separator: ",")
    }
    static func installation(_ entries: [AppleMusicInstalledEntry]) -> String {
        let positions = Set(entries.indices.prefix(3)).union(entries.indices.suffix(3)).sorted()
        return positions.map { index in
            let entry = entries[index]
            return "\(index):\(entry.entry.item.id)(kind:\(kind(entry.entry.item))) \(entry.systemID ?? "nil") aliases:[\(entry.identities.sorted().joined(separator: ","))]"
        }.joined(separator: ";")
    }
}
