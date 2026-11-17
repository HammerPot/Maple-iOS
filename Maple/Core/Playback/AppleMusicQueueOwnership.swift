import Foundation

/// Identity establishes membership, not proof that an arbitrary stop finished our queue.
struct AppleMusicQueueOwnership {
    struct Observation {
        var entry: UUID?
        var ended = false
        var stopped = false
        var decision = "not ours → external"
        var songMatched = false
        var entryMatched = false
        var stopReason = "unknown: no installed queue"
    }
    private var entries: [AppleMusicInstalledEntry] = []
    private var index = 0
    private var lastSystemID: String?
    private var lastPlaying: (index: Int, position: Double, duration: Double)?
    var ownsQueue: Bool { !entries.isEmpty }
    mutating func install(_ entries: [AppleMusicInstalledEntry], selected: UUID, observedID: String?) {
        self.entries = entries; index = entries.firstIndex { $0.entry.id == selected } ?? 0
        lastSystemID = observedID; lastPlaying = nil
    }
    mutating func relinquish() { entries = []; lastSystemID = nil; lastPlaying = nil }
    /// Called on existing position reads as well as notifications; never emits logs or events.
    mutating func recordPlaying(_ state: AppleMusicPlayerState) {
        guard ownsQueue, state.status == .playing, let item = state.item,
              !entries[index].identities.isDisjoint(with: item.musicIdentityIDs) else { return }
        lastPlaying = (index, state.position, item.duration)
    }
    mutating func observe(_ state: AppleMusicPlayerState) -> Observation {
        guard ownsQueue else { return Observation() }
        let matches = entries.indices.filter { position in
            state.item.map { !entries[position].identities.isDisjoint(with: $0.musicIdentityIDs) } ?? false
        }
        let matchingID = matches.first { state.occurrence != nil && entries[$0].systemID == state.occurrence }
        let entryMatched = entries.contains { state.occurrence != nil && $0.systemID == state.occurrence }
        var result = Observation(songMatched: !matches.isEmpty, entryMatched: entryMatched)
        if state.status == .stopped {
            // A stopped entry/time may already be nil or reset. Only prior playing evidence can
            // authorize automatic playback; identity membership by itself cannot authorize it.
            let final = entries.count - 1
            let finalWasPlaying = lastPlaying?.index == final
            let duration = lastPlaying?.duration ?? 0
            let nearEnd = duration > 0 && (lastPlaying?.position ?? 0) >= max(0, duration - 2)
            let sameOrAbsent = state.item == nil || matches.contains(final)
            result.ended = finalWasPlaying && nearEnd && sameOrAbsent
            result.stopped = !result.ended
            result.decision = "owned at index \(index)"
            result.stopReason = result.ended ? "natural end: final entry observed playing within 2s of end" : "unknown: finalPlaying=\(finalWasPlaying) nearEnd=\(nearEnd) sameOrAbsent=\(sameOrAbsent); wait for user"
            relinquish()
            return result
        }
        guard !matches.isEmpty else {
            result.stopReason = "takeover: current song not installed"
            relinquish(); return result
        }
        if state.status == .paused { lastPlaying = nil }
        let sameSong = matches.contains(index)
        let moved = state.occurrence != nil && state.occurrence != lastSystemID
        // A rewritten ID at the same song/position is not an advance. Exact installed IDs
        // still disambiguate duplicates; otherwise a move to another song prefers forward ties.
        let wrappedPosition = (lastPlaying?.position ?? 0) > 3 && state.position <= 2
        let expected = moved && (!sameSong || wrappedPosition) ? min(index + 1, entries.count - 1) : index
        index = matchingID ?? matches.min { abs($0 - expected) < abs($1 - expected) } ?? index
        lastSystemID = state.occurrence
        recordPlaying(state)
        result.entry = entries[index].entry.id
        result.decision = "owned at index \(index) / \(matchingID == nil ? "nearest position" : "entry ID")"
        return result
    }
}
