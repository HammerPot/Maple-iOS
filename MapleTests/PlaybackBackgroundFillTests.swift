import Foundation
import Testing
import UIKit
@testable import Maple

@MainActor final class FillAssertionProbe {
    var grants = true
    var begins = 0
    var ends = 0
    var onEnd: (() -> Void)?
    var active: Set<UIBackgroundTaskIdentifier> = []
    var expiration: (@MainActor @Sendable () -> Void)?
    func make() -> AppleMusicFillAssertion {
        AppleMusicFillAssertion(begin: { expiration in
            self.begins += 1; self.expiration = expiration
            guard self.grants else { return .invalid }
            let id = UIBackgroundTaskIdentifier(rawValue: self.begins)
            self.active.insert(id)
            return id
        }, end: { id in
            #expect(self.active.remove(id) != nil) // Detect double end, not just equal totals.
            self.ends += 1
            self.onEnd?()
        })
    }
}

@MainActor struct PlaybackBackgroundFillTests {
    private func songs() -> [PlaybackItem] {
        (0..<180).map { PlaybackItem(source: .appleMusic, id: "song\($0)", title: "Song \($0)", duration: 240) }
    }
    @Test(arguments: [false, true])
    func expirationBalancesImmediatelyAndLazyRetryDoesNotDuplicateAnInflightInsert(inFlight: Bool) async {
        let backend = ReviewMusicBackend(), assertions = FillAssertionProbe()
        let engine = AppleMusicPlaybackEngine(backend: backend, makeFillAssertion: assertions.make)
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: engine, reporter: PlaybackFakeReporter(), automaticSampling: false)
        let entered = TestGate(), release = TestGate()
        let suspend = { await entered.open(); await release.wait() }
        if inFlight { backend.nativeInsertion = suspend } else { backend.beforeAppend = suspend }
        backend.insertionSeconds = 102 // Models a native call returning after app suspension.
        let items = songs()
        await player.start(items); await entered.wait()
        #expect(assertions.begins == 1); #expect(assertions.ends == 0); #expect(assertions.active.count == 1)
        assertions.expiration?()
        #expect(assertions.ends == 1); #expect(assertions.active.isEmpty)
        // Repeated expiration/end notifications cannot double-end the assertion.
        assertions.expiration?(); #expect(assertions.ends == 1)
        await release.open(); await engine.waitForExtension()
        #expect(backend.appends == 1); #expect(backend.installed.count == (inFlight ? 100 : 50))
        #expect(player.isPlaying); #expect(!player.playingFromMusic)
        #expect(assertions.begins == 1); #expect(assertions.ends == 1)
        backend.onChange?(); await engine.waitForExtension(); #expect(backend.appends == 1)
        backend.insertionSeconds = 0
        let index = inFlight ? 85 : 35
        backend.change(items[index], id: "native", status: .playing)
        await engine.waitForExtension()
        #expect(backend.appends == 2)
        #expect(backend.installed.map(\.id) == Array(player.queue.entries.prefix(inFlight ? 150 : 100)).map(\.id))
        #expect(assertions.begins == 1); #expect(assertions.ends == 1) // Lazy work makes no new assertion.
        #expect(backend.prepares == 1); #expect(backend.plays == 1)
        player.stop()
    }
    @Test(arguments: [false, true])
    func stopAndTakeoverEndAssertionBeforeUncancellableInsertionDrains(takeover: Bool) async {
        let backend = ReviewMusicBackend(), assertions = FillAssertionProbe()
        let engine = AppleMusicPlaybackEngine(backend: backend, makeFillAssertion: assertions.make)
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: engine, reporter: PlaybackFakeReporter(), automaticSampling: false)
        let entered = TestGate(), release = TestGate(), drained = TestGate()
        backend.nativeInsertion = { await entered.open(); await release.wait(); await drained.open() }
        await player.start(songs()); await entered.wait()
        #expect(assertions.active.count == 1)
        if takeover {
            backend.change(PlaybackItem(source: .appleMusic, id: "Music", title: "Music"), id: "foreign", status: .paused)
        } else { player.stop() }
        #expect(assertions.begins == 1); #expect(assertions.ends == 1); #expect(assertions.active.isEmpty)
        #expect(backend.activeInsertions == 1) // Ending the assertion does not wait for native I/O.
        await release.open(); await drained.wait()
        player.stop(); #expect(assertions.ends == 1)
    }
    @Test(.timeLimit(.minutes(1)))
    func engineReleasedBeforeWorkerStartsStillEndsTheAssertion() async throws {
        let backend = ReviewMusicBackend(), assertions = FillAssertionProbe(), ended = TestGate()
        assertions.onEnd = { Task { await ended.open() } }
        var engine: AppleMusicPlaybackEngine? = AppleMusicPlaybackEngine(backend: backend, makeFillAssertion: assertions.make)
        let items = songs(); var queue = PlaybackQueue(); queue.replace(items, startingAt: 0, shuffle: false)
        try await engine?.configure(queue); try await engine?.load(items[0]); engine?.finishLoading()
        // No actor suspension between starting the worker and releasing its owner.
        backend.change(items[0], id: "native", status: .playing)
        #expect(assertions.active.count == 1)
        weak var releasedEngine = engine
        engine = nil
        #expect(releasedEngine == nil)
        await ended.wait()
        #expect(assertions.begins == 1); #expect(assertions.ends == 1); #expect(assertions.active.isEmpty)
        #expect(backend.appends == 0)
    }
    @Test func deniedAssertionDoesNotStartEagerWorkAndLeavesLazyRefillAvailable() async {
        let backend = ReviewMusicBackend(), assertions = FillAssertionProbe(); assertions.grants = false
        let engine = AppleMusicPlaybackEngine(backend: backend, makeFillAssertion: assertions.make)
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: engine, reporter: PlaybackFakeReporter(), automaticSampling: false)
        let items = songs()
        await player.start(items); await engine.waitForExtension()
        #expect(backend.appends == 0); #expect(backend.installed.count == 50); #expect(player.isPlaying)
        #expect(assertions.begins == 1); #expect(assertions.ends == 0); #expect(assertions.active.isEmpty)
        backend.change(items[35], id: "native", status: .playing)
        await engine.waitForExtension()
        #expect(backend.appends == 1); #expect(backend.installed.count == 100)
        #expect(assertions.begins == 1); #expect(assertions.ends == 0)
        player.stop()
    }
}
