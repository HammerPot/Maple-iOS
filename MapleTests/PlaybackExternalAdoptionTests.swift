import Foundation
import Testing
@testable import Maple

@MainActor struct PlaybackExternalAdoptionTests {
    private let song = PlaybackItem(source: .appleMusic, id: "external", title: "Music.app song", artist: "Artist")
    @Test func musicAppIsAdoptedBeforeFirstLoadAndAfterStopWithoutReplacingQueue() async {
        let apple = PlaybackFakeEngine(), reporter = PlaybackFakeReporter()
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: apple, reporter: reporter, automaticSampling: false)
        apple.external = ExternalPlaybackState(item: song, occurrence: "external-1")
        apple.isPlaying = true; apple.position = 23
        player.refresh(); await player.waitForReports()
        #expect(player.currentItem == song); #expect(player.isPlaying)
        #expect(reporter.snapshots.last?.position == 23)
        #expect(apple.loadCount == 0); #expect(apple.stopCount == 0)
        player.stop(); await player.waitForReports()
        apple.isPlaying = true
        apple.external = ExternalPlaybackState(item: song, occurrence: "external-2")
        apple.onEvent?(.stateChanged); await player.waitForReports()
        #expect(player.currentItem == song); #expect(player.isPlaying)
        #expect(reporter.snapshots.last?.playing == true); #expect(apple.loadCount == 0)
        #expect(apple.stopCount == 1)
    }
    @Test func disabledOrUnauthorizedObservationCannotAdopt() {
        let apple = PlaybackFakeEngine()
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: apple, reporter: PlaybackFakeReporter(), automaticSampling: false)
        apple.external = ExternalPlaybackState(item: song, occurrence: "external")
        apple.isPlaying = true; apple.externalAllowed = false
        player.refresh(); apple.onEvent?(.stateChanged)
        #expect(player.currentItem == nil); #expect(apple.stopCount == 0)
    }
    @Test func restoreLeavesAnExternallyPlayingSystemQueueUntouched() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let disk = PlaybackPersistence(url: url)
        var queue = PlaybackQueue(); queue.replace([PlaybackItem(source: .appleMusic, id: "saved", title: "Saved")], startingAt: 0, shuffle: false)
        try await disk.save(PlaybackCheckpoint(queue: queue, position: 44))
        let apple = PlaybackFakeEngine()
        apple.external = ExternalPlaybackState(item: song, occurrence: "external")
        apple.isPlaying = true
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: apple, reporter: PlaybackFakeReporter(), persistence: disk, automaticSampling: false)
        await player.restore { _ in nil }
        #expect(player.currentItem == song); #expect(apple.loadCount == 0); #expect(apple.stopCount == 0)
        await player.waitForSave()
    }
}
