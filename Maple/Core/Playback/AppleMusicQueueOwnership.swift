import Foundation

/// Song identities establish membership; system entry IDs are optional tie-breakers only.
struct AppleMusicQueueOwnership {
    private var entries: [AppleMusicInstalledEntry] = []
    private var index = 0
    private var lastSystemID: String?
    private var hasPlayed = false
    var ownsQueue: Bool { !entries.isEmpty }
    mutating func install(_ entries: [AppleMusicInstalledEntry], selected: UUID, observedID: String?) {
        self.entries = entries; index = entries.firstIndex { $0.entry.id == selected } ?? 0
        lastSystemID = observedID; hasPlayed = false
    }
    mutating func relinquish() { entries = []; lastSystemID = nil; hasPlayed = false }
    mutating func observe(_ state: AppleMusicPlayerState) -> (entry: UUID?, ended: Bool) {
        guard ownsQueue else { return (nil, false) }
        var selected: UUID?
        if let item = state.item {
            let matches = entries.indices.filter { !entries[$0].identities.isDisjoint(with: item.musicIdentityIDs) }
            guard !matches.isEmpty else { relinquish(); return (nil, false) }
            let sameSong = !entries[index].identities.isDisjoint(with: item.musicIdentityIDs)
            let moved = state.occurrence != nil && state.occurrence != lastSystemID
            let expected = moved && sameSong ? min(index + 1, entries.count - 1) : index
            let matchingID = matches.first { state.occurrence != nil && entries[$0].systemID == state.occurrence }
            index = matchingID ?? matches.min { abs($0 - expected) < abs($1 - expected) } ?? index
            lastSystemID = state.occurrence; selected = entries[index].entry.id
        }
        if state.status == .playing { hasPlayed = true }
        let ended = hasPlayed && state.status == .stopped
        if ended { hasPlayed = false }
        return (selected, ended)
    }
}
