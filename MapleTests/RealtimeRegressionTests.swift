import Foundation
import Testing
import SocketIO
@testable import Maple

@MainActor
struct PlaybackRecoveryTests {
    private var track: TrackSnapshot { TrackSnapshot(identity: "local:1", title: "Track", artist: "Artist", album: "Album", duration: 100, playing: true, position: 0) }
    private func reporter(_ socket: FakePlaybackTransport) -> PlaybackReporter {
        let reporter = PlaybackReporter(transport: socket, automaticHeartbeat: false)
        socket.ownership = { [weak reporter] in reporter?.ownershipChanged($0) }
        return reporter
    }
    @Test func rejectedUpdateWithoutForeignOwnerStartsNewClaim() async throws {
        let socket = FakePlaybackTransport(); let reporter = reporter(socket)
        await reporter.update(track); let old = try #require(reporter.playbackId)
        socket.rejectedUpdatesRemaining = 1
        await reporter.sendUpdate()
        #expect(reporter.ownsPlayback); #expect(reporter.playbackId != old)
        #expect(socket.events.filter { $0.0 == "playbackStart" }.count == 2)
    }
    @Test func nullOwnershipWhilePlayingReacquires() async throws {
        let socket = FakePlaybackTransport(); let reporter = reporter(socket)
        await reporter.update(track); let old = reporter.playbackId
        // The re-acquired claim's first update is sent only after the new start was acknowledged.
        let started = TestGate()
        socket.didSend = { event in if event == "playbackUpdate" { Task { await started.open() } } }
        reporter.ownershipChanged(nil)
        await started.wait()
        #expect(reporter.ownsPlayback); #expect(reporter.playbackId != old)
        #expect(socket.events.filter { $0.0 == "playbackStart" }.count == 2)
    }
    @Test(arguments: ["reconnect", "foreground", "lease"])
    func recoverableLossCreatesNewID(_ reason: String) async throws {
        let socket = FakePlaybackTransport(); let time = Locked<TimeInterval>(0)
        let reporter = PlaybackReporter(transport: socket, automaticHeartbeat: false, now: { time.read() })
        socket.ownership = { [weak reporter] in reporter?.ownershipChanged($0) }
        await reporter.update(track); let old = try #require(reporter.playbackId)
        switch reason {
        case "reconnect":
            socket.connected = false; reporter.disconnected()
            socket.connected = true; await reporter.connected()
        case "foreground": await reporter.sceneBecameActive()
        default: time.update { $0 = 91 }; await reporter.sendUpdate()
        }
        #expect(reporter.ownsPlayback); #expect(reporter.playbackId != old)
        #expect(socket.events.filter { $0.0 == "playbackStart" }.count == 2)
    }
    @Test(arguments: ["null", "foreground", "reconnect", "update"])
    func recoverableLossDoesNotClaimPausedTrack(_ reason: String) async {
        let socket = FakePlaybackTransport(); let reporter = reporter(socket)
        var paused = track; paused.playing = false
        await reporter.update(paused)
        let count = socket.events.count
        switch reason {
        case "null": reporter.ownershipChanged(nil); await Task.yield()
        case "foreground": await reporter.sceneBecameActive()
        case "reconnect": reporter.disconnected(); await reporter.connected()
        default: socket.rejectedUpdatesRemaining = 1; await reporter.sendUpdate()
        }
        #expect(socket.events.filter { $0.0 == "playbackStart" }.count == 1)
        #expect(socket.events.count <= count + 1)
        await reporter.stop()
    }
    @Test(arguments: ["resume", "explicitStart", "newTrack"])
    func foreignTakeoverIsTerminalUntilLocalIntent(_ intent: String) async {
        let socket = FakePlaybackTransport(); let reporter = reporter(socket)
        await reporter.update(track)
        reporter.ownershipChanged("foreign-device")
        reporter.ownershipChanged(nil)
        reporter.disconnected(); await reporter.connected(); await reporter.sceneBecameActive()
        var playing = track; playing.position = 30
        await reporter.update(playing, force: true); await reporter.sendUpdate()
        #expect(socket.events.filter { $0.0 == "playbackStart" }.count == 1)
        #expect(!reporter.ownsPlayback)
        switch intent {
        case "resume":
            var paused = track; paused.playing = false
            await reporter.update(paused); await reporter.update(track)
        case "explicitStart": await reporter.playbackStarted()
        default:
            await reporter.update(TrackSnapshot(identity: "local:2", title: "Next", artist: "Artist", album: "Album", duration: 100, playing: true, position: 0))
        }
        #expect(reporter.ownsPlayback)
        #expect(socket.events.filter { $0.0 == "playbackStart" }.count == 2)
    }
    @Test func ownershipAfterAckStillOwnsAndUploads() async {
        let socket = FakePlaybackTransport(); let gate = TestGate(); socket.ownershipGate = gate
        let uploaded = TestGate()
        let reporter = PlaybackReporter(transport: socket, automaticHeartbeat: false, upload: { _, _ in await uploaded.open() })
        socket.ownership = { [weak reporter] in reporter?.ownershipChanged($0) }
        await reporter.update(track, artwork: Data([1]))
        #expect(reporter.ownsPlayback)
        await gate.open(); await socket.ownershipDelivery?.value; await uploaded.wait()
        #expect(reporter.ownsPlayback)
    }
    @Test func foreignTakeoverDuringPendingAckCannotOwn() async {
        let socket = FakePlaybackTransport(); let reporter = reporter(socket); socket.suspendStart = true
        let start = Task { await reporter.update(track) }
        while socket.pendingStart == nil { await Task.yield() }
        reporter.ownershipChanged("foreign-device")
        socket.pendingStart?.resume(returning: PlaybackReply(ok: true, error: nil))
        await start.value
        #expect(!reporter.ownsPlayback)
        await reporter.sceneBecameActive()
        #expect(socket.events.count == 1)
    }
    @Test func trackChangeWhileStartPendingDropsOldAckAndArtwork() async {
        let socket = FakePlaybackTransport(); let uploaded = Locked<[String]>([])
        let uploadFinished = TestGate()
        let reporter = PlaybackReporter(transport: socket, automaticHeartbeat: false, upload: { _, id in uploaded.update { $0.append(id) }; await uploadFinished.open() })
        socket.ownership = { [weak reporter] in reporter?.ownershipChanged($0) }
        socket.suspendStart = true
        let first = Task { await reporter.update(track, artwork: Data([1])) }
        while socket.pendingStart == nil { await Task.yield() }
        let pending = socket.pendingStart; socket.pendingStart = nil; socket.suspendStart = false
        await reporter.update(TrackSnapshot(identity: "local:2", title: "Next", artist: "Artist", album: "Album", duration: 100, playing: true, position: 0), artwork: Data([2]))
        let id = reporter.playbackId
        pending?.resume(returning: PlaybackReply(ok: true, error: nil)); await first.value; await uploadFinished.wait()
        #expect(reporter.ownsPlayback); #expect(reporter.snapshot?.identity == "local:2")
        #expect(uploaded.read() == [id].compactMap { $0 })
    }
    @Test func automaticHeartbeatUsesInjectedIntervalAndFreshPosition() async {
        let socket = FakePlaybackTransport(); let sleeper = TestSleeper(); let sent = TestGate()
        let reporter = PlaybackReporter(transport: socket, heartbeatInterval: .seconds(7), sleep: { try await sleeper.sleep($0) })
        socket.ownership = { [weak reporter] in reporter?.ownershipChanged($0) }
        await reporter.update(track)
        var fresh = track; fresh.position = 27
        reporter.snapshotProvider = { fresh }
        socket.didSend = { event in if event == "playbackUpdate" { Task { await sent.open() } } }
        await sleeper.waitForSleep(); await sleeper.advance(); await sent.wait()
        #expect(await sleeper.delays.first == .seconds(7))
        #expect(socket.events.last?.1.position == 27)
        await reporter.stop()
    }
    @Test func rejectedStartIsNotRetriedByPassivePollingOnlyByExplicitTriggers() async {
        let socket = FakePlaybackTransport(); var errors = 0
        let reporter = PlaybackReporter(transport: socket, automaticHeartbeat: false, reportError: { _ in errors += 1 })
        socket.ownership = { [weak reporter] in reporter?.ownershipChanged($0) }
        socket.response = PlaybackReply(ok: false, error: "Invalid playback.")
        await reporter.update(track)
        // The Apple Music poll re-reports the same playing snapshot every second.
        for second in 1...5 { var tick = track; tick.position = Double(second); await reporter.update(tick) }
        #expect(socket.events.filter { $0.0 == "playbackStart" }.count == 1); #expect(errors == 1)
        socket.response = PlaybackReply(ok: true, error: nil)
        await reporter.sceneBecameActive()
        #expect(reporter.ownsPlayback)
        #expect(socket.events.filter { $0.0 == "playbackStart" }.count == 2)
    }
    @Test func reacquisitionDoesNotAnnounceTheSameTrackAgain() async {
        let socket = FakePlaybackTransport(); let reporter = reporter(socket); var announced: [String] = []
        reporter.didStart = { snapshot, _ in announced.append(snapshot.identity) }
        await reporter.update(track)
        await reporter.sceneBecameActive()
        socket.rejectedUpdatesRemaining = 1; await reporter.sendUpdate()
        #expect(socket.events.filter { $0.0 == "playbackStart" }.count == 3)
        #expect(announced == ["local:1"])
        await reporter.update(TrackSnapshot(identity: "local:2", title: "Next", artist: "Artist", album: "Album", duration: 100, playing: true, position: 0))
        #expect(announced == ["local:1", "local:2"])
    }
    @Test func sessionResetIsSynchronousAndDropsSnapshot() async {
        let socket = FakePlaybackTransport(); let reporter = reporter(socket)
        await reporter.update(track); reporter.resetSession(); await reporter.connected()
        #expect(reporter.playbackId == nil); #expect(reporter.snapshot == nil); #expect(!reporter.ownsPlayback)
        #expect(socket.events.filter { $0.0 == "playbackStart" }.count == 1)
    }
}

@MainActor
struct RealtimeAdapterTests {
    private func make(openSocket: @escaping (SocketIOClient) -> Void = { _ in }, sleeper: TestSleeper = TestSleeper()) throws -> MapleRealtime {
        let realtime = MapleRealtime(openSocket: openSocket, retrySleep: { try await sleeper.sleep($0) })
        let http = try testHTTP { _ in throw URLError(.unsupportedURL) }
        realtime.connect(cookies: http.sessionCookies)
        return realtime
    }
    @Test func ackTimeoutAndNonObjectsAreSafe() {
        for payload: [Any] in [["NO ACK"], [NSNull()], [true], [42], [[1, 2]], [], [["bad": Date()]]] {
            #expect(PlaybackReply.parse(ackValues: payload) == nil)
        }
        #expect(PlaybackReply.parse(ackValues: [["ok": true]])?.ok == true)
        #expect(PlaybackReply.parse(ackValues: [["ok": false, "error": "Expired"]])?.error == "Expired")
    }
    @Test func reconnectReleasesReporterAndClearsRPC() async throws {
        let realtime = try make(); let socket = try #require(realtime.socket)
        var disconnects = 0; realtime.onDisconnect = { disconnects += 1 }
        socket.didConnect(toNamespace: "/", payload: nil)
        socket.handleEvent("rpcUpdate", data: [["playing": true, "title": "Previous account"]], isInternalMessage: true)
        #expect(realtime.connected); #expect(realtime.lastRPCUpdate?.title == "Previous account")
        socket.setReconnecting(reason: "Transport closed")
        #expect(!realtime.connected); #expect(disconnects == 1); #expect(realtime.lastRPCUpdate == nil)
        #expect(await realtime.send("playbackUpdate", payload: PlaybackPayload(playbackId: "old")) == nil)
        realtime.disconnect()
    }
    @Test func eventParsingIgnoresNonObjectsAndAppliesOwnershipSynchronously() throws {
        let realtime = try make(); let socket = try #require(realtime.socket)
        var owners: [String?] = []; realtime.onOwnership = { owners.append($0) }
        for payload: [Any] in [["NO ACK"], [NSNull()], [true], [42], [[1, 2]], []] {
            socket.handleEvent("playbackOwnership", data: payload, isInternalMessage: true)
        }
        #expect(owners.isEmpty)
        socket.handleEvent("playbackOwnership", data: [["playbackId": "mine"]], isInternalMessage: true)
        #expect(owners.count == 1); #expect(owners.first == "mine")
        socket.handleEvent("rpcUpdate", data: [["playing": false]], isInternalMessage: true)
        realtime.disconnect(); #expect(realtime.lastRPCUpdate == nil)
    }
    @Test func transientSessionValidationRetriesWithoutParallelConnects() async throws {
        let sleeper = TestSleeper(); let opened = TestGate(); var opens = 0; var checks = 0
        let realtime = try make(openSocket: { _ in opens += 1; if opens == 2 { Task { await opened.open() } } }, sleeper: sleeper)
        let socket = try #require(realtime.socket)
        realtime.validateSession = { checks += 1; return checks == 1 ? .unreachable : .valid }
        socket.didDisconnect(reason: "Got Disconnect")
        await sleeper.waitForSleep()
        // A second error while validation is retrying cannot launch another request.
        socket.handleClientEvent(.error, data: ["Network error"])
        #expect(checks == 1); #expect(opens == 1)
        await sleeper.advance(); await opened.wait()
        #expect(checks == 2); #expect(opens == 2)
        socket.setReconnecting(reason: "Connecting")
        realtime.sceneBecameActive(); await Task.yield()
        #expect(opens == 2)
        realtime.disconnect()
    }
    @Test func rejectedHandshakeWhileConnectingEndsFailedAttemptBeforeValidation() async throws {
        let validated = TestGate(); var checks = 0
        let realtime = try make(); let socket = try #require(realtime.socket)
        realtime.validateSession = { checks += 1; await validated.open(); return .invalid }
        socket.setReconnecting(reason: "Connecting")
        socket.handleClientEvent(.error, data: ["Authentication error: Invalid session"])
        await validated.wait()
        #expect(checks == 1); #expect(!realtime.connected)
        realtime.disconnect()
    }
}
