import Foundation
import Testing
@testable import Maple

struct PlaybackQueueTests {
    private func item(_ id: String) -> PlaybackItem { PlaybackItem(source: .local, id: id, title: id) }

    @Test func deletingUnrelatedTrackPreservesRepeatedCurrentOccurrence() {
        var queue = PlaybackQueue()
        var a = item("A"); a.libraryID = UUID()
        var b = item("B"); b.libraryID = UUID()
        queue.replace([a, b, a, item("C")], startingAt: 2, shuffle: false)
        let current = queue.currentID
        queue.removeLibraryTracks(Set([b.libraryID].compactMap { $0 }))
        #expect(queue.currentID == current)
        #expect(queue.index == 1)
        let transition1 = queue.advance(natural: false); #expect(transition1)
        #expect(queue.current?.item.id == "C")
    }
    @Test func shufflePreservesCurrentAndRestoresOriginalOrder() {
        var queue = PlaybackQueue()
        queue.replace([item("A"), item("B"), item("C"), item("D")], startingAt: 2, shuffle: false)
        let original = queue.entries; let selected = queue.currentID
        queue.setShuffle(true)
        #expect(queue.entries.first?.id == selected)
        #expect(Set(queue.entries.map(\.id)) == Set(original.map(\.id)))
        queue.setShuffle(false)
        #expect(queue.entries == original); #expect(queue.currentID == selected)
    }
    @Test func repeatOneOnlyRepeatsOnNaturalEndAndOffDoesNotWrap() {
        var queue = PlaybackQueue()
        queue.replace([item("A"), item("B")], startingAt: 0, shuffle: false)
        queue.repeatMode = .one
        let transition2 = queue.advance(natural: true); #expect(transition2); #expect(queue.current?.item.id == "A")
        let transition3 = queue.advance(natural: false); #expect(transition3); #expect(queue.current?.item.id == "B")
        queue.repeatMode = .off
        let transition4 = queue.advance(natural: true); #expect(!transition4)
        queue.repeatMode = .all
        let transition5 = queue.advance(natural: true); #expect(transition5); #expect(queue.current?.item.id == "A")
        let transition6 = queue.previous(); #expect(transition6); #expect(queue.current?.item.id == "B")
    }
    @Test func enqueueReorderAndRemoveUseOccurrences() {
        var queue = PlaybackQueue()
        queue.replace([item("A"), item("B"), item("C")], startingAt: 0, shuffle: false)
        queue.enqueue([item("A")], next: true)
        #expect(queue.entries.map(\.item.id) == ["A", "A", "B", "C"])
        #expect(Set(queue.entries.map(\.id)).count == 4)
        queue.moveUpcoming(from: IndexSet(integer: 2), to: 0)
        #expect(queue.entries.map(\.item.id) == ["A", "C", "A", "B"])
        let id = queue.entries[2].id
        queue.remove([id]); #expect(queue.entries.map(\.item.id) == ["A", "C", "B"])
        queue.setShuffle(true); queue.setShuffle(false)
        #expect(queue.entries.map(\.item.id) == ["A", "C", "B"])
    }
}
