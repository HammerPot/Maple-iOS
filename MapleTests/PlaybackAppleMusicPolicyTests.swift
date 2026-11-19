import Foundation
import MusicKit
import Testing
@testable import Maple

struct PlaybackAppleMusicPolicyTests {
    private func item(_ id: String, _ source: PlaybackItem.Source) -> PlaybackItem {
        PlaybackItem(source: source, id: id, title: id)
    }
    @Test func installedSegmentCannotRepeatAllInsideMixedQueue() {
        let a = item("A", .appleMusic), b = item("B", .local)
        var queue = PlaybackQueue(); queue.replace([a, b], startingAt: 0, shuffle: false); queue.repeatMode = .all
        #expect(AppleMusicQueuePolicy.context(for: queue, fallback: a).map(\.item.id) == ["A"])
        #expect(AppleMusicQueuePolicy.repeatMode(for: queue) == .none)
        queue.replace([b, a, item("C", .appleMusic), item("D", .local)], startingAt: 1, shuffle: false)
        queue.repeatMode = .all
        #expect(AppleMusicQueuePolicy.context(for: queue, fallback: a).map(\.item.id) == ["A", "C"])
        #expect(AppleMusicQueuePolicy.repeatMode(for: queue) == .none)
        queue.repeatMode = .one
        #expect(AppleMusicQueuePolicy.repeatMode(for: queue) == .one)
    }
    @Test func allAppleQueueCanRepeatInMusicButOffNeverRepeats() {
        let a = item("A", .appleMusic)
        var queue = PlaybackQueue(); queue.replace([a, item("B", .appleMusic)], startingAt: 0, shuffle: false); queue.repeatMode = .all
        #expect(AppleMusicQueuePolicy.repeatMode(for: queue) == .all)
        queue.repeatMode = .off
        #expect(AppleMusicQueuePolicy.repeatMode(for: queue) == .none)
    }
}
