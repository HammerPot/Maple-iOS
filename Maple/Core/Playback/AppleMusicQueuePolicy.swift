import MusicKit

/// Music owns only a contiguous segment. Maple wraps mixed queues at their real boundary.
enum AppleMusicQueuePolicy {
    static func repeatMode(for queue: PlaybackQueue) -> MusicKit.MusicPlayer.RepeatMode {
        switch queue.repeatMode {
        case .one: return .one
        case .all where !queue.entries.isEmpty && queue.entries.allSatisfy({ $0.item.source == .appleMusic }): return .all
        case .off, .all: return .none
        }
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
