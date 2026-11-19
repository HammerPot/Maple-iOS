import Foundation
import Testing
@testable import Maple

@MainActor struct PlaybackReview2Tests {
    private func item(_ name: String, source: PlaybackItem.Source = .local) -> PlaybackItem {
        var item = PlaybackItem(source: source, id: name, title: name, duration: 180)
        if source == .local { item.libraryID = UUID() }
        return item
    }
    @Test func externalAdoptionPreservesMapleQueueAndCheckpointAcrossForegroundAndEnd() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let disk = PlaybackPersistence(url: url), local = PlaybackFakeEngine(), apple = PlaybackFakeEngine()
        let player = PlaybackController(local: local, apple: apple, reporter: PlaybackFakeReporter(), persistence: disk, automaticSampling: false)
        let a = item("A"), b = item("B")
        await player.start([a,b]); local.position = 42; player.pause(); await player.waitForSave()
        let queue = player.queue, bytes = try Data(contentsOf: url)
        apple.external = ExternalPlaybackState(item: item("Music", source: .appleMusic), occurrence: "foreign")
        apple.isPlaying = true; player.refresh(); player.save(); await player.waitForSave()
        #expect(player.queue == queue); #expect(player.currentItem?.title == "Music")
        #expect(try Data(contentsOf: url) == bytes)
        player.setShuffle(true); player.setRepeat(.all); player.enqueue([item("C")], next: true)
        player.moveUpcoming(from: [0], to: 1); player.removeEntries(Set(queue.upcoming.map(\.id)))
        #expect(player.queue == queue); #expect(apple.loadCount == 0)
        apple.isPlaying = false; apple.external = nil; apple.onEvent?(.stateChanged)
        #expect(player.currentItem == a); #expect(!player.isPlaying); #expect(player.position.seconds == 42)
        #expect(player.queue == queue)
    }
    @Test func restoredPausedLocalAndAppleNeverClaimOrAnnounceUntilAudioPlays() async throws {
        for source: PlaybackItem.Source in [.local, .appleMusic] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: url) }
            let disk = PlaybackPersistence(url: url), song = item("Saved", source: source)
            var queue = PlaybackQueue(); queue.replace([song], startingAt: 0, shuffle: false)
            try await disk.save(PlaybackCheckpoint(queue: queue, position: 31))
            let socket = FakePlaybackTransport(), reporter = PlaybackReporter(transport: socket, automaticHeartbeat: false)
            var announcements = 0, starts = 0
            reporter.didStart = { _,_ in announcements += 1 }
            let player = PlaybackController(local: PlaybackFakeEngine(), apple: PlaybackFakeEngine(), reporter: reporter, persistence: disk, automaticSampling: false)
            player.recordStart = { _ in starts += 1 }
            await player.restore { _ in song }; player.refresh(); await player.seek(to: 44)
            await player.waitForReports(); await reporter.connected(); await reporter.sceneBecameActive()
            #expect(socket.events.isEmpty); #expect(announcements == 0); #expect(starts == 0)
            await player.resume(); await player.waitForReports()
            #expect(socket.events.filter { $0.0 == "playbackStart" }.count == 1)
            #expect(announcements == 1); #expect(starts == (source == .local ? 1 : 0))
            player.stop(); await player.waitForReports(); await player.waitForSave()
        }
    }
    @Test func samplingNeverRewritesQueueDuringPlaybackOrPause() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let disk = PlaybackPersistence(url: url), engine = PlaybackFakeEngine()
        let player = PlaybackController(local: engine, apple: PlaybackFakeEngine(), reporter: PlaybackFakeReporter(), persistence: disk, automaticSampling: false)
        await player.start((0..<1000).map { item(String($0)) }); await player.waitForSave()
        let bytes = try Data(contentsOf: url)
        for position in 1...100 { engine.position = Double(position); player.sample() }
        await player.waitForSave(); #expect(try Data(contentsOf: url) == bytes)
        player.pause(); await player.waitForSave(); let paused = try Data(contentsOf: url)
        for _ in 0..<100 { player.sample() }
        await player.waitForSave(); #expect(try Data(contentsOf: url) == paused)
    }
    @Test func pauseDuringLocalLoadDoesNotTouchUnrelatedMusic() async {
        let local = SuspendedPlaybackEngine(), apple = PlaybackFakeEngine()
        let player = PlaybackController(local: local, apple: apple, reporter: PlaybackFakeReporter(), automaticSampling: false)
        local.suspendLoads = true
        let start = Task { await player.start([item("Local")]) }
        await local.waitForLoad(1)
        apple.isPlaying = true
        player.pause()
        #expect(apple.isPlaying)
        local.release(1); await start.value
        #expect(!player.isPlaying); #expect(apple.isPlaying)
    }
    @Test func passivePausePlayingFlickerCannotReclaimForeignOwnership() async {
        let socket = FakePlaybackTransport()
        let actual = PlaybackReporter(transport: socket, automaticHeartbeat: false)
        var snapshot = TrackSnapshot(identity: "local:A", title: "A", artist: "", album: "", playing: true, position: 0)
        await actual.update(snapshot); actual.ownershipChanged("other-device")
        snapshot.playing = false; await actual.update(snapshot)
        snapshot.playing = true; await actual.update(snapshot)
        #expect(socket.events.filter { $0.0 == "playbackStart" }.count == 1)
        await actual.playbackStarted()
        #expect(socket.events.filter { $0.0 == "playbackStart" }.count == 2)
        await actual.stop()
    }
}


extension PlaybackReview2Tests {
    @Test func samplerSleepsOnlyWhileAudibleAndRestartsAfterResume() async throws {
        let sleeper = TestSleeper(), engine = PlaybackFakeEngine()
        let player = PlaybackController(local: engine, apple: PlaybackFakeEngine(), reporter: PlaybackFakeReporter(), samplingSleep: { try await sleeper.sleep($0) })
        #expect(await sleeper.delays.isEmpty)
        await player.start([item("A")]); await sleeper.waitForSleep()
        player.pause(); try #require(sleeper.cancellationCount.read() == 1)
        await sleeper.waitForNoSleeps()
        #expect(await sleeper.pendingCount == 0)
        await player.resume(); await sleeper.waitForSleeps(1)
        player.stop(); await sleeper.waitForNoSleeps()
        #expect(await sleeper.pendingCount == 0); #expect(!player.isPlaying)
    }
}

extension PlaybackReview2Tests {
    @Test func automaticInterruptionResumeDoesNotTakeForeignClaimButExplicitResumeCan() async {
        let socket = FakePlaybackTransport()
        let actual = PlaybackReporter(transport: socket, automaticHeartbeat: false)
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: PlaybackFakeEngine(), reporter: actual, automaticSampling: false)
        await player.start([item("A")]); await player.waitForReports()
        actual.ownershipChanged("desktop")
        player.pause(); await player.waitForReports()
        await player.resume(userInitiated: false); await player.waitForReports()
        #expect(socket.events.filter { $0.0 == "playbackStart" }.count == 1)
        player.pause(); await player.waitForReports()
        await player.resume(); await player.waitForReports()
        #expect(socket.events.filter { $0.0 == "playbackStart" }.count == 2)
        player.stop(); await player.waitForReports()
    }
}
