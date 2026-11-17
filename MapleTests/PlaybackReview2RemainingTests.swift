import Foundation
import Testing
@testable import Maple

@MainActor struct PlaybackReview2RemainingTests {
    private func item(_ id: String) -> PlaybackItem { PlaybackItem(source: .appleMusic, id: id, title: id) }


    @Test func unreadableNaturalAdvanceSkipsFileAndContinuesWithoutStartingIt() async {
        let engine = PlaybackFakeEngine(), reporter = PlaybackFakeReporter()
        engine.failedItemIDs = ["B"]
        let player = PlaybackController(local: engine, apple: PlaybackFakeEngine(), reporter: reporter, automaticSampling: false)
        let items = ["A","B","C"].map { PlaybackItem(source: .local, id: $0, title: $0) }
        var notices = 0; player.onError = { _ in notices += 1 }
        await player.start(items); await player.next(natural: true); await player.waitForReports()
        #expect(player.currentItem?.id == "C"); #expect(player.isPlaying)
        #expect(!player.queue.entries.contains { $0.item.id == "B" }); #expect(notices == 1)
        #expect(!reporter.snapshots.contains { $0.title == "B" })
    }
    @Test func randomShuffleWithoutASelectionCanChooseADifferentFirstSong() async {
        var chosen = 0
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: PlaybackFakeEngine(), reporter: PlaybackFakeReporter(), automaticSampling: false, chooseShuffleStart: { range in
            defer { chosen += 1 }; return chosen % range.count
        })
        let items = (0..<50).map { PlaybackItem(source: .local, id: String($0), title: String($0)) }
        var first: Set<String> = []
        for _ in 0..<10 { await player.start(items, shuffle: true); if let id = player.currentItem?.id { first.insert(id) } }
        #expect(first.count > 1)
    }
}

extension PlaybackReview2RemainingTests {
    @Test func allUnreadableNaturalQueueMakesOnlyOnePassEvenWithRepeatAll() async {
        let engine = PlaybackFakeEngine()
        let player = PlaybackController(local: engine, apple: PlaybackFakeEngine(), reporter: PlaybackFakeReporter(), automaticSampling: false)
        let items = ["A","B","C"].map { PlaybackItem(source: .local, id: $0, title: $0) }
        await player.start(items); player.setRepeat(.all)
        engine.failedItemIDs = ["A","B","C"]
        await player.next(natural: true)
        #expect(player.currentItem == nil); #expect(player.queue.entries.isEmpty)
        #expect(engine.loadCount == 4); #expect(!player.isPlaying)
    }
    @Test func explicitShuffleSelectionStillPinsChosenTrack() async {
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: PlaybackFakeEngine(), reporter: PlaybackFakeReporter(), automaticSampling: false, chooseShuffleStart: { _ in 2 })
        let items = ["A","B","C"].map { PlaybackItem(source: .local, id: $0, title: $0) }
        await player.start(items, shuffle: true)
        #expect(player.currentItem?.id == "C")
        await player.start(items, startingAt: 1, shuffle: true)
        #expect(player.currentItem?.id == "B")
    }
}
