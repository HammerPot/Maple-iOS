import Foundation
import Testing
@testable import Maple

@MainActor struct PlaybackWindowTests {
    private func songs(_ count: Int) -> [PlaybackItem] {
        (0..<count).map { PlaybackItem(source: .appleMusic, id: "song\($0)", title: "Song \($0)", duration: 240) }
    }
    @Test func fakeModelsNativeMutationAfterPrepareThrowsAndReplacementAlreadyPlays() async throws {
        let backend = ReviewMusicBackend(); backend.watchdogEntryCount = 861
        let old = songs(861).map { PlaybackEntry(item: $0) }
        do { _ = try await backend.prepare(old, selected: old[0].id, progress: { _ in }); Issue.record("Expected watchdog") }
        catch { #expect((error as? URLError)?.code == .timedOut) }
        let replacement = PlaybackEntry(item: PlaybackItem(source: .appleMusic, id: "replacement", title: "Replacement"))
        _ = try await backend.prepare([replacement], selected: replacement.id, progress: { _ in })
        try await backend.play()
        #expect(backend.state.item?.id == "replacement")
        backend.deliverLateNativeMutations()
        #expect(backend.state.item?.id == old[0].item.id)
        #expect(backend.state.status == .paused)
    }
    @Test func boundedPreparePreventsTheWatchdogAndItsPostReturnMutationFromKillingReplacement() async {
        let backend = ReviewMusicBackend(); backend.watchdogEntryCount = 861
        let release = TestGate(); backend.beforeAppend = { await release.wait() }
        let socket = FakePlaybackTransport(), reporter = PlaybackReporter(transport: socket, automaticHeartbeat: false)
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: AppleMusicPlaybackEngine(backend: backend), reporter: reporter, automaticSampling: false)
        let large = songs(861)
        await player.start(large)
        #expect(backend.installed.count == 50); #expect(player.queue.entries.count == 861)
        await player.start([PlaybackItem(source: .appleMusic, id: "replacement", title: "Replacement")])
        await release.open()
        backend.deliverLateNativeMutations() // Would reset the replacement with an unbounded prepare.
        await player.waitForReports()
        #expect(backend.timeouts == 0); #expect(player.isPlaying)
        #expect(backend.state.item?.id == "replacement"); #expect(!player.playingFromMusic)
        #expect(player.currentItem?.id == "replacement")
        player.stop(); await player.waitForReports()
    }
    @Test func eagerFillCompletesWithoutMovementAndEnablesNativeRepeatWithoutAnotherClaim() async {
        let backend = ReviewMusicBackend(), engine = AppleMusicPlaybackEngine(backend: backend)
        let socket = FakePlaybackTransport(), reporter = PlaybackReporter(transport: socket, automaticHeartbeat: false)
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: engine, reporter: reporter, automaticSampling: false)
        let entered = TestGate(), release = TestGate()
        backend.nativeInsertion = { await entered.open(); await release.wait() }
        let items = songs(861)
        await player.start(items); await entered.wait()
        player.setRepeat(.all); await player.waitForLoad()
        #expect(backend.installed.count == 50); #expect(backend.mode == .off)
        // Notifications must keep working during the fill, including pause/resume.
        player.pause(); #expect(!player.isPlaying)
        await player.resume()
        await player.waitForReports()
        let claims = socket.events.filter { $0.0 == "playbackStart" }.count
        await release.open(); await engine.waitForExtension(); await player.waitForReports()
        #expect(backend.installed.map(\.id) == player.queue.entries.map(\.id))
        #expect(backend.appends == 17); #expect(backend.maxInsertions == 1)
        #expect(backend.prepares == 1); #expect(backend.plays == 2)
        #expect(backend.mode == .all); #expect(player.isPlaying); #expect(!player.playingFromMusic)
        #expect(socket.events.filter { $0.0 == "playbackStart" }.count == claims)
        player.stop(); await player.waitForReports()
    }
    @Test func replacementDrainsInflightInsertAndDropsRemainingOldBatches() async {
        let backend = ReviewMusicBackend(), engine = AppleMusicPlaybackEngine(backend: backend)
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: engine, reporter: PlaybackFakeReporter(), automaticSampling: false)
        let entered = TestGate(), release = TestGate(), replacementResolving = TestGate()
        backend.nativeInsertion = { await entered.open(); await release.wait() }
        await player.start(songs(861)); await entered.wait()
        backend.resolve = { entries, _, _ in
            await replacementResolving.open()
            return AppleMusicInstallation(entries: entries.map { AppleMusicInstalledEntry(entry: $0, identities: $0.item.musicIdentityIDs, systemID: nil) })
        }
        let replacement = PlaybackItem(source: .appleMusic, id: "replacement", title: "Replacement")
        let next = Task { await player.start([replacement]) }
        await replacementResolving.wait()
        #expect(backend.installed.count == 50); #expect(backend.activeInsertions == 1)
        #expect(backend.mutations == ["prepare:song0"])
        await release.open(); await next.value; await engine.waitForExtension()
        #expect(backend.mutations == ["prepare:song0", "append:song50", "prepare:replacement"])
        #expect(backend.appends == 1); #expect(backend.maxInsertions == 1)
        #expect(backend.installed.map(\.item.id) == ["replacement"])
        #expect(player.currentItem?.id == "replacement"); #expect(player.isPlaying); #expect(!player.playingFromMusic)
        player.stop()
    }
    @Test(arguments: [false, true])
    func failedOrSlowInsertionStopsEagerWorkAndLaterMovementRefillsLazily(slow: Bool) async {
        let backend = ReviewMusicBackend(), engine = AppleMusicPlaybackEngine(backend: backend)
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: engine, reporter: PlaybackFakeReporter(), automaticSampling: false)
        var attempts = 0, errors = 0
        player.onError = { _ in errors += 1 }
        backend.nativeInsertion = {
            attempts += 1
            if !slow && attempts == 1 { throw URLError(.timedOut) }
        }
        backend.insertionSeconds = slow ? 2.1 : 0
        let items = songs(180)
        await player.start(items); await engine.waitForExtension()
        #expect(backend.appends == 1); #expect(backend.installed.count == (slow ? 100 : 50))
        #expect(player.isPlaying); #expect(errors == 0)
        // Same-item notifications cannot spin a retry loop.
        backend.onChange?(); await engine.waitForExtension(); #expect(backend.appends == 1)
        backend.insertionSeconds = 0
        let index = slow ? 85 : 35
        backend.change(items[index], id: "native", status: .playing, position: 12)
        await engine.waitForExtension()
        #expect(backend.appends == 2); #expect(backend.installed.count == (slow ? 150 : 100))
        #expect(player.queue.index == index); #expect(player.position.seconds == 12)
        #expect(backend.prepares == 1); #expect(backend.plays == 1); #expect(player.isPlaying)
        player.stop()
    }
    @Test func middleWindowIncludesPreviousEntriesAndNeverRepeatsAnIncompletePrefix() async {
        let backend = ReviewMusicBackend(), engine = AppleMusicPlaybackEngine(backend: backend)
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: engine, reporter: PlaybackFakeReporter(), automaticSampling: false)
        let items = songs(150)
        await player.start(items, startingAt: 120)
        #expect(backend.installed.map(\.item.id) == Array(items[110..<150]).map(\.id))
        #expect(backend.state.item == items[120])
        player.setRepeat(.all); await player.waitForLoad()
        #expect(backend.mode == .off)
        backend.change(items[119], id: "previous", status: .playing)
        #expect(player.queue.index == 119); #expect(!player.playingFromMusic)
        player.stop()
    }
}
