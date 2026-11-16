import Foundation
import Testing
@testable import Maple

/// Continuations deliberately ignore cancellation, like an in-flight framework prepare operation.
@MainActor final class SuspendedPlaybackEngine: PlaybackEngine {
    var onEvent: ((PlaybackEngineEvent) -> Void)?
    var position = 0.0
    var duration = 180.0
    var rate = 1.0
    var isPlaying = false
    var suspendLoads = false
    var loads = 0
    var plays = 0
    var contexts: [PlaybackQueue] = []
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    private var observers: [Int: CheckedContinuation<Void, Never>] = [:]
    func configure(_ queue: PlaybackQueue) async throws { contexts.append(queue) }
    func load(_ item: PlaybackItem) async throws {
        loads += 1
        let number = loads
        if suspendLoads {
            await withCheckedContinuation { continuation in
                pending[number] = continuation
                observers.removeValue(forKey: number)?.resume()
            }
        }
        position = 0; isPlaying = false
    }
    func waitForLoad(_ number: Int) async {
        if pending[number] != nil { return }
        await withCheckedContinuation { observers[number] = $0 }
    }
    func release(_ number: Int) { pending.removeValue(forKey: number)?.resume() }
    func play() async throws { plays += 1; isPlaying = true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false; position = 0 }
    func seek(to seconds: Double) async { position = seconds }
}

@MainActor struct PlaybackInterleavingTests {
    private let a = PlaybackItem(source: .appleMusic, id: "A", title: "A")
    private let b = PlaybackItem(source: .appleMusic, id: "B", title: "B")
    private let c = PlaybackItem(source: .appleMusic, id: "C", title: "C")
    private func controller(_ engine: SuspendedPlaybackEngine) -> PlaybackController {
        PlaybackController(local: PlaybackFakeEngine(), apple: engine, reporter: PlaybackFakeReporter(), automaticSampling: false)
    }
    @Test func pauseDuringInitialLoadWinsOverAutoplayAndSeekIsRetained() async {
        let engine = SuspendedPlaybackEngine(), player = controller(engine)
        engine.suspendLoads = true
        let start = Task { await player.start([a]) }
        await engine.waitForLoad(1)
        player.pause(); await player.seek(to: 42)
        engine.release(1); await start.value
        #expect(engine.plays == 0); #expect(!player.isPlaying)
        #expect(player.position.seconds == 42); #expect(!player.isLoading)
    }
    @Test func pauseAndSeekDuringQueueReloadWinAndReconcileRunsAfterLoading() async {
        let engine = SuspendedPlaybackEngine(), player = controller(engine)
        await player.start([a]); engine.position = 12; engine.suspendLoads = true
        player.enqueue([b], next: false)
        await engine.waitForLoad(2)
        player.pause(); await player.seek(to: 73)
        engine.release(2); await player.waitForLoad()
        #expect(engine.plays == 1); #expect(!player.isPlaying)
        #expect(player.position.seconds == 73); #expect(!player.isLoading)
    }
    @Test func overlappingEditsAreSerializedAndObsoleteReloadCannotPlay() async {
        let engine = SuspendedPlaybackEngine(), player = controller(engine)
        await player.start([a]); engine.position = 12; engine.suspendLoads = true
        player.enqueue([b], next: false)
        await engine.waitForLoad(2)
        player.enqueue([c], next: false)
        await player.seek(to: 91)
        #expect(engine.loads == 2)
        engine.release(2)
        await engine.waitForLoad(3)
        #expect(engine.plays == 1)
        engine.release(3); await player.waitForLoad()
        #expect(engine.contexts.last?.entries.map(\.item.id) == ["A", "B", "C"])
        #expect(engine.position == 91); #expect(player.position.seconds == 91)
        #expect(engine.plays == 2); #expect(player.isPlaying); #expect(!player.isLoading)
    }
}
