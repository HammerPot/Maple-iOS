import Foundation

/// Queue entry IDs, unlike song IDs, prove that Music is still playing Maple's installed queue.
struct AppleMusicQueueOwnership {
    private(set) var entries: [String: UUID] = [:]
    private(set) var ownsQueue = false
    private var hasPlayed = false
    mutating func install(_ entries: [String: UUID]) { self.entries = entries; ownsQueue = true; hasPlayed = false }
    mutating func append(_ entries: [String: UUID]) { self.entries.merge(entries) { _, new in new } }
    mutating func remove(_ occurrences: Set<String>) { entries = entries.filter { !occurrences.contains($0.key) } }
    mutating func relinquish() { entries = [:]; ownsQueue = false; hasPlayed = false }
    mutating func observe(occurrence: String?, playing: Bool, stopped: Bool) -> (entry: UUID?, ended: Bool) {
        if ownsQueue, let occurrence, entries[occurrence] == nil { relinquish() }
        if ownsQueue, playing { hasPlayed = true }
        let ended = ownsQueue && hasPlayed && stopped
        if ended { hasPlayed = false }
        return (occurrence.flatMap { entries[$0] }, ended)
    }
}
