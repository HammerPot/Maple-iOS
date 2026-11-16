import Foundation

/// Track identity and queue occurrence identity are deliberately separate.
struct PlaybackQueue: Codable, Equatable, Sendable {
    private(set) var entries: [PlaybackEntry] = []
    private(set) var original: [PlaybackEntry] = []
    private(set) var currentID: UUID?
    private(set) var shuffled = false
    var repeatMode = PlaybackRepeat.off
    var index: Int? { entries.firstIndex { $0.id == currentID } }
    var current: PlaybackEntry? { index.map { entries[$0] } }
    var upcoming: [PlaybackEntry] { index.map { Array(entries.dropFirst($0 + 1)) } ?? entries }

    mutating func replace(_ items: [PlaybackItem], startingAt index: Int, shuffle: Bool) {
        entries = items.map { PlaybackEntry(item: $0) }; original = entries
        currentID = entries.indices.contains(index) ? entries[index].id : entries.first?.id
        shuffled = false
        setShuffle(shuffle)
    }
    mutating func rebaseLocalItems(_ resolve: (UUID) -> PlaybackItem?) {
        for index in entries.indices {
            if let id = entries[index].item.libraryID, let item = resolve(id) { entries[index].item = item }
        }
        for index in original.indices {
            if let id = original[index].item.libraryID, let item = resolve(id) { original[index].item = item }
        }
    }
    mutating func select(_ id: UUID) { if entries.contains(where: { $0.id == id }) { currentID = id } }
    mutating func setShuffle(_ enabled: Bool) {
        guard enabled != shuffled else { return }
        shuffled = enabled
        if enabled, let current {
            entries = [current] + entries.filter { $0.id != current.id }.shuffled()
        } else { entries = original }
    }
    mutating func enqueue(_ items: [PlaybackItem], next: Bool) {
        let new = items.map { PlaybackEntry(item: $0) }
        let insertion = next ? min((index ?? -1) + 1, entries.count) : entries.count
        entries.insert(contentsOf: new, at: insertion)
        let originalInsertion = next ? (original.firstIndex { $0.id == currentID }.map { $0 + 1 } ?? original.count) : original.count
        original.insert(contentsOf: new, at: originalInsertion)
        if currentID == nil { currentID = entries.first?.id }
    }
    @discardableResult mutating func advance(natural: Bool) -> Bool {
        guard let index, !entries.isEmpty else { return false }
        if natural && repeatMode == .one { return true }
        if index + 1 < entries.count { currentID = entries[index + 1].id; return true }
        if repeatMode == .all { currentID = entries.first?.id; return true }
        return false
    }
    @discardableResult mutating func previous() -> Bool {
        guard let index else { return false }
        if index > 0 { currentID = entries[index - 1].id; return true }
        if repeatMode == .all { currentID = entries.last?.id; return true }
        return false
    }
    mutating func remove(_ ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }; original.removeAll { ids.contains($0.id) }
        if let currentID, ids.contains(currentID) { self.currentID = nil }
    }
    mutating func removeLibraryTracks(_ ids: Set<UUID>) {
        remove(Set(entries.filter { $0.item.libraryID.map(ids.contains) == true }.map(\.id)))
    }
    mutating func moveUpcoming(from offsets: IndexSet, to destination: Int) {
        let prefix = (index ?? -1) + 1
        var tail = Array(entries.dropFirst(prefix))
        let valid = offsets.filter { tail.indices.contains($0) }
        let moved = valid.map { tail[$0] }
        for offset in valid.reversed() { tail.remove(at: offset) }
        let adjusted = min(max(0, destination - valid.filter { $0 < destination }.count), tail.count)
        tail.insert(contentsOf: moved, at: adjusted)
        entries = Array(entries.prefix(prefix)) + tail
        // Explicit edits become the restored order, preserving any already-played original entries.
        let tailIDs = Set(tail.map(\.id))
        original.removeAll { tailIDs.contains($0.id) }
        let insertion = original.firstIndex { $0.id == currentID }.map { $0 + 1 } ?? original.count
        original.insert(contentsOf: tail, at: insertion)
    }
}
