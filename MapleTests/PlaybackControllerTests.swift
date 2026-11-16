import Foundation
import Testing
@testable import Maple

@MainActor final class PlaybackFakeEngine: PlaybackEngine {
    var onEvent: ((PlaybackEngineEvent) -> Void)?
    var position = 0.0
    var duration = 180.0
    var rate = 1.0
    var isPlaying = false
    var loaded: PlaybackItem?
    var failLoad = false
    var seeks: [Double] = []
    func load(_ item: PlaybackItem) async throws {
        if failLoad { throw LibraryError.unreadableAudio }
        loaded = item; position = 0
    }
    func play() async throws { isPlaying = true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false; loaded = nil; position = 0 }
    func seek(to seconds: Double) async { position = seconds; seeks.append(seconds) }
}
@MainActor final class PlaybackFakeReporter: PlaybackReporting {
    var snapshots: [TrackSnapshot] = []
    var starts = 0
    var stops = 0
    func update(_ value: TrackSnapshot, artwork: Data?, force: Bool) async { snapshots.append(value) }
    func playbackStarted() async { starts += 1 }
    func stop() async { stops += 1 }
}
@MainActor private final class PlaybackFakeClock { var time = 0.0 }

@MainActor struct PlaybackControllerTests {
    private func item(_ title: String) -> PlaybackItem {
        var value = PlaybackItem(source: .local, id: title, title: title)
        value.libraryID = UUID(); return value
    }
    @Test func explicitStopClosesPlayAndFlushesFinalListeningExactlyOnce() async {
        let engine = PlaybackFakeEngine(); let clock = PlaybackFakeClock()
        let controller = PlaybackController(local: engine, apple: PlaybackFakeEngine(), reporter: PlaybackFakeReporter(), automaticSampling: false, clock: { clock.time })
        var starts = 0; var ends: [Bool] = []; var listened = 0.0
        controller.recordStart = { _ in starts += 1 }
        controller.recordEnd = { _, completed in ends.append(completed) }
        controller.recordListening = { _, seconds in listened += seconds }
        await controller.start([item("A")])
        clock.time = 2.75
        controller.stop(); controller.stop()
        #expect(starts == 1); #expect(ends == [false]); #expect(listened == 2.75)
        #expect(controller.currentItem == nil); #expect(!engine.isPlaying)
    }
    @Test func failedLoadCannotPlayOrAttributeOldAudioToRequestedTrack() async {
        let engine = PlaybackFakeEngine()
        let controller = PlaybackController(local: engine, apple: PlaybackFakeEngine(), reporter: PlaybackFakeReporter(), automaticSampling: false)
        let a = item("A"), b = item("B")
        var starts: [UUID] = []; var errors = 0
        controller.recordStart = { starts.append($0) }; controller.onError = { _ in errors += 1 }
        await controller.start([a])
        engine.failLoad = true
        await controller.start([b])
        #expect(starts == [a.libraryID].compactMap { $0 }); #expect(errors == 1)
        #expect(controller.currentItem == nil); #expect(controller.snapshot == nil)
        #expect(engine.loaded == nil); #expect(!engine.isPlaying); #expect(!controller.isPlaying)
    }
    @Test func pauseResumeSeekAndNaturalRepeatHaveDistinctSemantics() async {
        let engine = PlaybackFakeEngine(); let reporter = PlaybackFakeReporter(); let clock = PlaybackFakeClock()
        let controller = PlaybackController(local: engine, apple: PlaybackFakeEngine(), reporter: reporter, automaticSampling: false, clock: { clock.time })
        var starts = 0; var ends: [Bool] = []; var listened = 0.0
        controller.recordStart = { _ in starts += 1 }; controller.recordEnd = { _, value in ends.append(value) }
        controller.recordListening = { _, value in listened += value }
        await controller.start([item("A"), item("B")])
        let firstIdentity = controller.snapshot?.identity
        clock.time = 2; controller.pause()
        clock.time = 30; await controller.resume()
        await controller.seek(to: 90)
        clock.time = 31; controller.sample()
        #expect(starts == 1); #expect(listened == 3)
        #expect(engine.seeks == [90])
        controller.setRepeat(.one); await controller.next(natural: true)
        #expect(starts == 2); #expect(ends == [true])
        #expect(controller.snapshot?.identity != firstIdentity)
        await controller.next()
        #expect(controller.currentItem?.title == "B"); #expect(ends == [true, false])
    }
    @Test func positionSamplesDoNotPublishReportingUpdates() async {
        let engine = PlaybackFakeEngine(); let reporter = PlaybackFakeReporter()
        let controller = PlaybackController(local: engine, apple: PlaybackFakeEngine(), reporter: reporter, automaticSampling: false)
        await controller.start([item("A")])
        await controller.waitForReports()
        let initial = reporter.snapshots.count
        for second in 1...40 { engine.position = Double(second); controller.sample() }
        await controller.waitForReports()
        #expect(reporter.snapshots.count == initial)
        #expect(controller.position.seconds == 40)
        await controller.seek(to: 100); await controller.waitForReports()
        #expect(reporter.snapshots.count == initial + 1)
        #expect(reporter.snapshots.last?.position == 100)
    }
    @Test func previousRestartsAfterThreeSecondsOtherwiseGoesBack() async {
        let engine = PlaybackFakeEngine()
        let controller = PlaybackController(local: engine, apple: PlaybackFakeEngine(), reporter: PlaybackFakeReporter(), automaticSampling: false)
        await controller.start([item("A"), item("B")], startingAt: 1)
        engine.position = 7; await controller.previous()
        #expect(controller.currentItem?.title == "B"); #expect(engine.position == 0)
        await controller.previous(); #expect(controller.currentItem?.title == "A")
    }
    @Test func deletingCurrentStopsAndRemovingOthersPreservesCurrentOccurrence() async {
        let engine = PlaybackFakeEngine()
        let controller = PlaybackController(local: engine, apple: PlaybackFakeEngine(), reporter: PlaybackFakeReporter(), automaticSampling: false)
        let a = item("A"), b = item("B"), c = item("C")
        await controller.start([a, b, a, c], startingAt: 2)
        controller.removeLibraryTracks(Set([b.libraryID].compactMap { $0 }))
        await controller.next(); #expect(controller.currentItem?.title == "C")
        controller.removeLibraryTracks(Set([c.libraryID].compactMap { $0 }))
        #expect(controller.currentItem == nil); #expect(!controller.isPlaying)
    }
    @Test func engineStateAndRateChangesDriveReportingForBothSources() async {
        let local = PlaybackFakeEngine(), apple = PlaybackFakeEngine(), reporter = PlaybackFakeReporter()
        let controller = PlaybackController(local: local, apple: apple, reporter: reporter, automaticSampling: false)
        await controller.start([PlaybackItem(source: .appleMusic, id: "1", title: "Apple")])
        apple.isPlaying = false; apple.onEvent?(.stateChanged)
        await controller.waitForReports(); #expect(reporter.snapshots.last?.playing == false)
        apple.isPlaying = true; apple.rate = 1.5; apple.onEvent?(.stateChanged)
        await controller.waitForReports(); #expect(reporter.snapshots.last?.playbackRate == 1.5)
        await controller.start([item("Local")]); #expect(!apple.isPlaying); #expect(local.isPlaying)
    }
    @Test func externalMusicChangesSelectTheActualQueueOccurrenceAndRefreshIdentity() async {
        let apple = PlaybackFakeEngine(), reporter = PlaybackFakeReporter()
        let controller = PlaybackController(local: PlaybackFakeEngine(), apple: apple, reporter: reporter, automaticSampling: false)
        let a = PlaybackItem(source: .appleMusic, id: "A", title: "A", artworkURL: URL(fileURLWithPath: "/nonexistent/A"))
        let b = PlaybackItem(source: .appleMusic, id: "B", title: "B", artworkURL: URL(fileURLWithPath: "/nonexistent/B"))
        await controller.start([a, b, a])
        let occurrence = controller.queue.entries[2].id
        let previousIdentity = controller.snapshot?.identity
        apple.onEvent?(.itemChanged(a, occurrence: "system-occurrence-3", queueEntryID: occurrence))
        await controller.waitForReports()
        #expect(controller.queue.index == 2)
        #expect(controller.snapshot?.identity != previousIdentity)
        #expect(reporter.snapshots.last?.title == "A")
        controller.stop()
    }
    @Test func restoresQueueOccurrenceAndPositionPaused() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("queue.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let disk = PlaybackPersistence(url: url), engine = PlaybackFakeEngine()
        let controller = PlaybackController(local: engine, apple: PlaybackFakeEngine(), reporter: PlaybackFakeReporter(), persistence: disk, automaticSampling: false)
        let a = item("A"), b = item("B")
        await controller.start([a, b, a], startingAt: 2)
        await controller.seek(to: 23); await controller.waitForSave()
        let newEngine = PlaybackFakeEngine()
        let restored = PlaybackController(local: newEngine, apple: PlaybackFakeEngine(), reporter: PlaybackFakeReporter(), persistence: disk, automaticSampling: false)
        await restored.restore { id in [a, b].first { $0.libraryID == id } }
        #expect(restored.queue.index == 2); #expect(newEngine.position == 23)
        #expect(!restored.isPlaying); #expect(restored.currentItem?.id == "A")
    }
}
