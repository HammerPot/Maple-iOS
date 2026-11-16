import Foundation
import Testing
@testable import Maple

@MainActor struct PlaybackArtworkReportingTests {
    private let a = PlaybackItem(source: .appleMusic, id: "A", title: "A")
    private let b = PlaybackItem(source: .appleMusic, id: "B", title: "B")
    @Test(arguments: [false, true]) func artworkCannotDelayStopOrNewTrack(switchTrack: Bool) async {
        let socket = FakePlaybackTransport(), entered = TestGate(), release = TestGate(), finished = TestGate()
        var uploads: [String] = []
        let reporter = PlaybackReporter(transport: socket, automaticHeartbeat: false, upload: { _, id in uploads.append(id) })
        socket.ownership = { [weak reporter] in reporter?.ownershipChanged($0) }
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: PlaybackFakeEngine(), reporter: reporter, automaticSampling: false)
        reporter.snapshotProvider = { [weak player] in player?.snapshot }
        reporter.artworkProvider = { identity in
            if identity.contains("apple:A:") {
                await entered.open(); await release.wait(); await finished.open()
                return Data([1])
            }
            return nil
        }
        await player.start([a]); await entered.wait(); await player.waitForReports()
        let oldID = reporter.playbackId
        // The start and first state update were ACKed before the image returned.
        #expect(socket.events.contains { $0.0 == "playbackUpdate" })
        if switchTrack { await player.start([b]) } else { player.stop() }
        await player.waitForReports()
        if switchTrack {
            #expect(socket.events.contains { $0.0 == "playbackStart" && $0.1.title == "B" })
            #expect(reporter.snapshot?.title == "B")
        } else {
            #expect(socket.events.last?.0 == "playbackStop")
            #expect(socket.events.last?.1.playbackId == oldID)
        }
        #expect(uploads.isEmpty)
        await release.open(); await finished.wait(); await reporter.waitForArtwork()
        #expect(!uploads.contains(oldID ?? ""))
        #expect(socket.events.filter { $0.0 == "playbackStart" && $0.1.title == "A" }.count == 1)
        player.stop(); await player.waitForReports()
    }
    @Test func heartbeatContinuesWhileArtworkIsSuspended() async {
        let socket = FakePlaybackTransport(), entered = TestGate(), release = TestGate(), sent = TestGate()
        let sleeper = TestSleeper()
        let reporter = PlaybackReporter(transport: socket, sleep: { try await sleeper.sleep($0) })
        reporter.artworkProvider = { _ in await entered.open(); await release.wait(); return nil }
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: PlaybackFakeEngine(), reporter: reporter, automaticSampling: false)
        await player.start([a]); await entered.wait(); await player.waitForReports()
        let before = socket.events.count
        socket.didSend = { if $0 == "playbackUpdate" { Task { await sent.open() } } }
        await sleeper.waitForSleep(); await sleeper.advance(); await sent.wait()
        #expect(socket.events.count > before)
        player.stop(); await player.waitForReports(); await release.open()
    }
    @Test func queuedSnapshotsCannotReplayObsoleteTracksAfterPendingStartAcknowledgement() async {
        let socket = FakePlaybackTransport(), sent = TestGate()
        socket.suspendStart = true
        let reporter = PlaybackReporter(transport: socket, automaticHeartbeat: false)
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: PlaybackFakeEngine(), reporter: reporter, automaticSampling: false)
        reporter.snapshotProvider = { [weak player] in player?.snapshot }
        socket.didSend = { if $0 == "playbackStart" { Task { await sent.open() } } }
        await player.start([a]); await sent.wait()
        // send() yields before installing the ACK continuation. Wait for that exact suspension.
        while socket.pendingStart == nil { await Task.yield() }
        await player.start([b])
        await player.start([PlaybackItem(source: .appleMusic, id: "C", title: "C")])
        socket.suspendStart = false
        socket.pendingStart?.resume(returning: PlaybackReply(ok: true, error: nil)); socket.pendingStart = nil
        await player.waitForReports()
        #expect(socket.events.filter { $0.0 == "playbackStart" }.compactMap { $0.1.title } == ["A", "C"])
        player.stop(); await player.waitForReports()
    }
}
