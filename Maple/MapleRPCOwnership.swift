import Foundation

/// A token change alone must never let an old client reclaim another client's playback.
struct MapleRPCOwnership {
    private(set) var generation: String?
    private(set) var pendingClaim = false

    mutating func reset() {
        generation = nil
        pendingClaim = false
    }

    mutating func queueClaim(_ claim: Bool) {
        pendingClaim = pendingClaim || claim
    }

    mutating func receive(generation: String, owned: Bool) -> Bool? {
        guard !generation.isEmpty, generation.utf8.count <= 128 else { return nil }
        let changed = self.generation != generation
        self.generation = generation
        if pendingClaim {
            pendingClaim = false
            return true
        }
        return changed && owned ? false : nil
    }
}
