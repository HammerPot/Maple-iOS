import Foundation
import Testing
@testable import Maple

@MainActor struct PlaybackReview4Tests {
    private func song(_ id: String, duration: Double = 180) -> PlaybackItem {
        PlaybackItem(source: .appleMusic, id: id, title: id, duration: duration)
    }
    private func controller(_ backend: ReviewMusicBackend) -> PlaybackController {
        PlaybackController(local: PlaybackFakeEngine(), apple: AppleMusicPlaybackEngine(backend: backend), reporter: PlaybackFakeReporter(), automaticSampling: false)
    }
    @Test(arguments: [false, true])
    func musicAppSubsetOfInstalledSongsCannotRestartMapleOnStopOrForeground(_ foreground: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let backend = ReviewMusicBackend(), engine = AppleMusicPlaybackEngine(backend: backend)
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: engine, reporter: PlaybackFakeReporter(), persistence: PlaybackPersistence(url: url), automaticSampling: false)
        let receive = engine.onEvent; var ends = 0
        engine.onEvent = { event in if case .ended = event { ends += 1 }; receive?(event) }
        await player.start([song("A"),song("B"),song("C"),song("D")])
        // Music.app replaces Maple's queue with [A,B]; both identities belong to Maple's segment.
        backend.change(song("B"), id: "music-app-B", status: .playing, position: 179)
        player.sample(); await player.waitForSave()
        let queue = player.queue, position = player.position.seconds
        backend.change(song("B"), id: "music-app-B", status: .stopped, position: 0, notify: !foreground)
        if foreground { player.refresh() }
        await player.waitForSave()
        #expect(ends == 0); #expect(backend.prepares == 1); #expect(backend.plays == 1)
        #expect(!player.isPlaying); #expect(player.queue == queue); #expect(player.position.seconds == position)
        let saved = try await PlaybackPersistence(url: url).load()
        #expect(saved?.queue == queue); #expect(saved?.position == position)
        await player.resume(userInitiated: false)
        #expect(backend.prepares == 1); #expect(!player.isPlaying)
    }
    @Test(arguments: ["early-final", "unknown-duration", "reset-first", "never-played", "paused-near-end"])
    func uncertainStopsCannotEmitNaturalEnd(_ scenario: String) async throws {
        let backend = ReviewMusicBackend(), engine = AppleMusicPlaybackEngine(backend: backend)
        let a = song("A"), b = song("B", duration: scenario == "unknown-duration" ? 0 : 180)
        var queue = PlaybackQueue(); queue.replace([a,b], startingAt: 1, shuffle: false)
        try await engine.configure(queue); try await engine.load(b)
        var ended = 0, stopped = 0
        engine.onEvent = { event in if case .ended = event { ended += 1 }; if case .stopped = event { stopped += 1 } }
        if scenario != "never-played" {
            backend.change(b, id: "rewritten", status: .playing, position: (scenario == "reset-first" || scenario == "paused-near-end") ? 179 : 20)
            if scenario == "paused-near-end" { backend.change(b, id: "paused", status: .paused, position: 179) }
        }
        backend.change(scenario == "reset-first" ? a : b, id: "stop", status: .stopped, position: 180)
        #expect(ended == 0); #expect(stopped == 1)
        #expect(backend.prepares == 1); #expect(backend.plays == 0)
    }
    @Test func finalPlayingEvidenceAllowsOnlyTheActualSegmentBoundary() async throws {
        let backend = ReviewMusicBackend(), local = SuspendedPlaybackEngine()
        let engine = AppleMusicPlaybackEngine(backend: backend)
        let player = PlaybackController(local: local, apple: engine, reporter: PlaybackFakeReporter(), automaticSampling: false)
        let a = song("A"), b = song("B")
        let localItem = PlaybackItem(source: .local, id: "L", title: "L")
        await player.start([a,b,localItem])
        backend.change(b, id: "B-rewritten", status: .playing, position: 179)
        local.suspendLoads = true
        backend.change(nil, id: "stopped", status: .stopped)
        await local.waitForLoad(1)
        #expect(player.queue.current?.item.id == "L"); #expect(backend.prepares == 1)
        local.release(1); await player.waitForLoad()
        #expect(player.currentItem?.id == "L"); #expect(player.isPlaying)
    }
    @Test func duplicateForwardTiesFollowABABAndDoNotRestartEarlyFinalStop() async {
        let backend = ReviewMusicBackend(), player = controller(backend)
        let a = song("A"), b = song("B")
        await player.start([a,b,a,b])
        for (index, item) in [(1,b),(2,a),(3,b)] {
            backend.change(item, id: "rewritten-\(index)", status: .playing)
            #expect(player.queue.index == index)
        }
        // An early stop on the final duplicate is still a stop, not proof of completion.
        backend.change(b, id: "rewritten-3", status: .stopped)
        #expect(!player.isPlaying); #expect(player.queue.index == 3)
        #expect(backend.prepares == 1); #expect(backend.plays == 1)
    }
    @Test func entryIDsRewrittenAfterPrepareAndAfterPlayDoNotCreateAnotherClaimOrWebhook() async {
        let backend = ReviewMusicBackend(), socket = FakePlaybackTransport()
        let reporter = PlaybackReporter(transport: socket, automaticHeartbeat: false)
        var webhooks = 0; reporter.didStart = { _,_ in webhooks += 1 }
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: AppleMusicPlaybackEngine(backend: backend), reporter: reporter, automaticSampling: false)
        let a = song("A")
        await player.start([a,a,song("B")]); await player.waitForReports()
        let identity = player.snapshot?.identity, claim = reporter.playbackId
        for i in 0..<3 {
            backend.change(a, id: "rewritten-after-engine-read-\(i)", status: .playing, position: 10)
            await player.waitForReports()
            #expect(player.queue.index == 0); #expect(player.snapshot?.identity == identity)
        }
        backend.change(a, id: "rewritten-on-pause", status: .paused, position: 10)
        await player.waitForReports()
        backend.change(a, id: "rewritten-on-resume", status: .playing, position: 10)
        await player.waitForReports()
        #expect(socket.events.filter { $0.0 == "playbackStart" }.count == 1)
        #expect(reporter.playbackId == claim); #expect(webhooks == 1)
        player.stop(); await player.waitForReports()
    }
    @Test func abandonedResolutionCannotInstallAndLocalChoiceDoesNotWait() async {
        let backend = ReviewMusicBackend(), entered = TestGate(), release = TestGate()
        backend.resolve = { entries,_,_ in
            await entered.open(); await release.wait()
            return AppleMusicInstallation(entries: entries.map { AppleMusicInstalledEntry(entry: $0, identities: $0.item.musicIdentityIDs, systemID: nil) })
        }
        let socket = FakePlaybackTransport(), reporter = PlaybackReporter(transport: socket, automaticHeartbeat: false)
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: AppleMusicPlaybackEngine(backend: backend), reporter: reporter, automaticSampling: false)
        let old = Task { await player.start([song("Abandoned")]) }
        await entered.wait()
        // This must return before release, even if the framework ignores cancellation while awaiting.
        await player.start([PlaybackItem(source: .local, id: "Local", title: "Local")])
        #expect(player.isPlaying); #expect(player.currentItem?.id == "Local")
        await release.open(); await old.value; await player.waitForReports()
        #expect(backend.installed.isEmpty); #expect(backend.plays == 0)
        #expect(!socket.events.contains { $0.0 == "playbackStart" && $0.1.title == "Abandoned" })
        player.stop(); await player.waitForReports()
    }
    @Test func nativePreparationDrainsBeforeNewAssignmentWithoutAbandonedClaim() async {
        let backend = ReviewMusicBackend(), entered = TestGate(), release = TestGate(), nextResolved = TestGate()
        backend.afterAssignment = { await entered.open(); await release.wait() }
        let socket = FakePlaybackTransport(), reporter = PlaybackReporter(transport: socket, automaticHeartbeat: false)
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: AppleMusicPlaybackEngine(backend: backend), reporter: reporter, automaticSampling: false)
        let old = Task { await player.start([song("A")]) }
        await entered.wait(); backend.afterAssignment = nil
        backend.resolve = { entries, _, _ in
            await nextResolved.open()
            return AppleMusicInstallation(entries: entries.map { AppleMusicInstalledEntry(entry: $0, identities: $0.item.musicIdentityIDs) })
        }
        let next = Task { await player.start([song("B")]) }
        await nextResolved.wait()
        #expect(backend.installed.map(\.item.id) == ["A"])
        #expect(backend.stops == 0); #expect(backend.plays == 0)
        await release.open(); await old.value; await next.value; await player.waitForReports()
        #expect(backend.installed.map(\.item.id) == ["B"])
        #expect(backend.plays == 1); #expect(player.isPlaying); #expect(!player.playingFromMusic)
        #expect(socket.events.filter { $0.0 == "playbackStart" }.map { $0.1.title } == ["B"])
        player.stop(); await player.waitForReports()
    }
    @Test func failureAfterQueueAssignmentNeverStartsOrStopsAnotherQueue() async {
        let backend = ReviewMusicBackend(); backend.afterAssignment = { throw URLError(.timedOut) }
        let socket = FakePlaybackTransport(), reporter = PlaybackReporter(transport: socket, automaticHeartbeat: false)
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: AppleMusicPlaybackEngine(backend: backend), reporter: reporter, automaticSampling: false)
        await player.start([song("A")]); await player.waitForReports()
        #expect(backend.stops == 0); #expect(backend.state.status == .paused)
        #expect(backend.plays == 0); #expect(!player.isPlaying)
        #expect(!socket.events.contains { $0.0 == "playbackStart" })
    }
    @Test func coldLibraryIdentityBatchesDeferOnlyFailedNamespacesAndRetry() async throws {
        var offline = true, calls: [[String]] = []
        let resolver = AppleMusicTrackResolver<String>(library: { ids in
            calls.append(ids)
            return Dictionary(uniqueKeysWithValues: ids.filter { $0 != "i.missing" && $0 != "i.offline" }.map { ($0,$0) })
        }, catalog: { _ in if offline { throw URLError(.notConnectedToInternet) }; return ["555":"found"] })
        var selected = song("i.selected"); selected.appleMusicIdentity = AppleMusicIdentity(libraryID: selected.id)
        var missing = song("i.missing"); missing.appleMusicIdentity = AppleMusicIdentity(libraryID: missing.id)
        var deferred = song("i.offline"); deferred.appleMusicIdentity = AppleMusicIdentity(libraryID: deferred.id, catalogID: "555")
        let entries = [selected,missing,deferred].map { PlaybackEntry(item: $0) }
        let first = try await resolver.context(entries, selected: entries[0].id)
        #expect(first.values.map { $0.0.id } == [entries[0].id])
        #expect(first.unavailable == [entries[1].id]); #expect(!first.unavailable.contains(entries[2].id))
        #expect(Set(calls[0]) == ["i.selected","i.missing","i.offline"])
        offline = false
        let retry = try await resolver.context([entries[0],entries[2]], selected: entries[0].id)
        #expect(retry.values.count == 2); #expect(retry.unavailable.isEmpty)
    }
}
