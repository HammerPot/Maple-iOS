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
        let socket = FakePlaybackTransport(), reporter = PlaybackReporter(transport: socket, automaticHeartbeat: false)
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: AppleMusicPlaybackEngine(backend: backend), reporter: reporter, automaticSampling: false)
        let large = songs(861)
        await player.start(large)
        #expect(backend.installed.count == 50); #expect(player.queue.entries.count == 861)
        await player.start([PlaybackItem(source: .appleMusic, id: "replacement", title: "Replacement")])
        backend.deliverLateNativeMutations() // Would reset the replacement with an unbounded prepare.
        await player.waitForReports()
        #expect(backend.timeouts == 0); #expect(player.isPlaying)
        #expect(backend.state.item?.id == "replacement"); #expect(!player.playingFromMusic)
        #expect(player.currentItem?.id == "replacement")
        player.stop(); await player.waitForReports()
    }
    @Test func forwardMovementExtendsWithoutPrepareRestartOrDuplicateClaimAndPartialRepeatStaysOff() async {
        let backend = ReviewMusicBackend(), engine = AppleMusicPlaybackEngine(backend: backend)
        let socket = FakePlaybackTransport(), reporter = PlaybackReporter(transport: socket, automaticHeartbeat: false)
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: engine, reporter: reporter, automaticSampling: false)
        let items = songs(120)
        await player.start(items); player.setRepeat(.all); await player.waitForLoad()
        #expect(backend.installed.count == 50); #expect(backend.mode == .off)
        let current = player.queue.entries[35]
        backend.change(items[35], id: "native35", status: .playing, position: 12)
        await player.waitForReports()
        let claims = socket.events.filter { $0.0 == "playbackStart" }.count
        let prepares = backend.prepares, plays = backend.plays
        await engine.waitForExtension(); await player.waitForReports()
        #expect(backend.installed.map(\.id) == Array(player.queue.entries.prefix(100)).map(\.id))
        #expect(backend.appends == 1); #expect(backend.prepares == prepares); #expect(backend.plays == plays)
        #expect(player.queue.currentID == current.id); #expect(player.position.seconds == 12)
        #expect(socket.events.filter { $0.0 == "playbackStart" }.count == claims)
        backend.change(items[85], id: "native85", status: .playing)
        await engine.waitForExtension()
        #expect(backend.installed.count == 120); #expect(backend.mode == .all)
        #expect(!player.playingFromMusic)
        player.stop(); await player.waitForReports()
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
