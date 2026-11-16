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

extension PlaybackExternalAdoptionTests {
    @Test func restoringAppleCheckpointOnlyLoadsMusicAfterExplicitPlay() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let disk = PlaybackPersistence(url: url)
        let song = PlaybackItem(source: .appleMusic, id: "12345", title: "Saved", duration: 180)
        var queue = PlaybackQueue(); queue.replace([song], startingAt: 0, shuffle: false)
        try await disk.save(PlaybackCheckpoint(queue: queue, position: 44))
        let apple = PlaybackFakeEngine(), local = PlaybackFakeEngine()
        // No adoptable Music state (setting off, or Music.app paused); unrelated playback is untouched.
        let player = PlaybackController(local: local, apple: apple, reporter: PlaybackFakeReporter(), persistence: disk, automaticSampling: false)
        await player.restore { _ in nil }
        #expect(player.currentItem == song); #expect(!player.isPlaying)
        #expect(player.snapshot?.position == 44)
        #expect(apple.loadCount == 0); #expect(apple.stopCount == 0); #expect(local.stopCount == 0)
        await player.seek(to: 61)
        #expect(apple.seeks.isEmpty); #expect(player.snapshot?.position == 61)
        await player.resume()
        #expect(apple.loadCount == 1); #expect(apple.position == 61); #expect(player.isPlaying)
        await player.waitForSave()
    }
}

extension PlaybackExternalAdoptionTests {
    @Test func adoptedMusicUsesSystemSkipWithoutInstallingAMapleQueue() async {
        let apple = PlaybackFakeEngine()
        apple.external = ExternalPlaybackState(item: song, occurrence: "system-queue")
        apple.isPlaying = true
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: apple, reporter: PlaybackFakeReporter(), automaticSampling: false)
        player.refresh()
        await player.next(); await player.previous()
        #expect(apple.externalSkips == [true, false])
        #expect(apple.loadCount == 0); #expect(apple.stopCount == 0)
        #expect(player.isPlaying)
    }
}
