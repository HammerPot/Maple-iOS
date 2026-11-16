import Foundation
import Testing
@testable import Maple

private final class LibraryPlayerFixtureBundle: NSObject { }

@MainActor
@Suite(.serialized)
struct LibraryPlayerTests {
    @Test(.timeLimit(.minutes(1)))
    func realPlaybackCountsStartsSkipsAndNaturalCompletionsAndStopsOnDeletion() async throws {
        let fixture = try #require(Bundle(for: LibraryPlayerFixtureBundle.self).url(forResource: "tags23", withExtension: "mp3"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(root: root)
        await store.load()
        let summary = await store.importFiles([fixture])
        #expect(summary.imported == 1)
        let track = try #require(store.tracks.first)
        let manager = AudioPlayerManager.shared
        let previousStore = manager.libraryStore
        let previousReporter = manager.playbackReporter
        manager.stop(); manager.libraryStore = store; manager.playbackReporter = nil
        defer {
            manager.stop(); manager.removeLibraryTracks([track.id]); manager.libraryStore = previousStore
            manager.playbackReporter = previousReporter
            try? FileManager.default.removeItem(at: root)
        }
        store.willDeleteTracks = { ids in manager.removeLibraryTracks(ids) }
        manager.setQueue([track]); manager.play()
        #expect(manager.isPlaying); #expect(store.statistics[track.id]?.plays == 1)
        manager.pause(); manager.play()
        #expect(store.statistics[track.id]?.plays == 1) // resume is not a new start
        manager.playNext()
        #expect(store.statistics[track.id]?.skips == 1)
        #expect(store.statistics[track.id]?.plays == 2)
        let deadline = ContinuousClock.now + .seconds(4)
        while store.statistics[track.id, default: TrackStatistics()].completions == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect((store.statistics[track.id]?.completions ?? 0) >= 1)
        #expect(store.statistics[track.id]?.skips == 1) // auto-advance never increments skips
        #expect((store.statistics[track.id]?.listeningSeconds ?? 0) > 0)
        try await store.deleteTracks([track.id])
        #expect(!manager.isPlaying); #expect(manager.currentSong == nil); #expect(manager.queue.isEmpty)
    }
}
