import Foundation
import MusicKit

/// Music owns only a contiguous segment. Maple wraps mixed queues at their real boundary.
enum AppleMusicQueuePolicy {
    // Physical iPhone: 50 entries prepared in 0.59s; 861 timed out at 9s.
    static let windowSize = 50
    static let previousCount = 10
    static let refillThreshold = 15
    static func window(in entries: [PlaybackEntry], selected: UUID) -> Range<Int> {
        let index = entries.firstIndex { $0.id == selected } ?? 0
        let lower = max(0, index - previousCount)
        return lower..<min(entries.count, lower + windowSize)
    }
    static func mapleRepeatMode(for queue: PlaybackQueue) -> PlaybackRepeat {
        if queue.repeatMode == .all && queue.entries.contains(where: { $0.item.source != .appleMusic }) { return .off }
        return queue.repeatMode
    }
    static func repeatMode(for queue: PlaybackQueue) -> MusicKit.MusicPlayer.RepeatMode {
        switch mapleRepeatMode(for: queue) { case .off: return .none; case .one: return .one; case .all: return .all }
    }
    static func context(for queue: PlaybackQueue, fallback: PlaybackItem) -> [PlaybackEntry] {
        guard let current = queue.index, queue.entries[current].item.source == .appleMusic else {
            return [PlaybackEntry(item: fallback)]
        }
        var lower = current, upper = current
        while lower > 0 && queue.entries[lower - 1].item.source == .appleMusic { lower -= 1 }
        while upper + 1 < queue.entries.count && queue.entries[upper + 1].item.source == .appleMusic { upper += 1 }
        return Array(queue.entries[lower...upper])
    }
}
