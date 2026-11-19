import Foundation
import Testing
@testable import Maple

private final class LibraryPlayerFixtureBundle: NSObject { }

@MainActor
@Suite(.serialized)
struct LibraryPlayerTests {
    private func waitUntilPlaying(_ manager: PlaybackController) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !manager.isPlaying, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }
    @Test(.timeLimit(.minutes(1)))
    func realPlaybackCountsStartsSkipsAndNaturalCompletionsAndStopsOnDeletion() async throws {
        let fixture = try #require(Bundle(for: LibraryPlayerFixtureBundle.self).url(forResource: "tags23", withExtension: "mp3"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(root: root)
        await store.load()
        let summary = await store.importFiles([fixture])
        #expect(summary.imported == 1)
        let track = try #require(store.tracks.first)
        let manager = PlaybackController(local: LocalPlaybackEngine(), apple: PlaybackFakeEngine(), reporter: PlaybackFakeReporter())
        manager.recordStart = { store.recordStart($0) }
        manager.recordListening = { store.recordListening($0, seconds: $1) }
        manager.recordEnd = { store.recordEnd($0, completed: $1) }
        defer { manager.stop(); try? FileManager.default.removeItem(at: root) }
        store.willDeleteTracks = { ids in manager.removeLibraryTracks(ids) }
        manager.setRepeat(.all)
        await manager.start([PlaybackItem(track: track, library: store)])
        await waitUntilPlaying(manager)
        #expect(manager.isPlaying); #expect(store.statistics[track.id]?.plays == 1)
        manager.pause(); await manager.resume(); await waitUntilPlaying(manager)
        #expect(store.statistics[track.id]?.plays == 1) // resume is not a new start
        await manager.next(); await waitUntilPlaying(manager)
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
        #expect(!manager.isPlaying); #expect(manager.currentItem == nil); #expect(manager.queue.entries.isEmpty)
    }
}
