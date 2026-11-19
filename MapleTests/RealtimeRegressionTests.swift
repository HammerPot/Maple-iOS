import Foundation
import Testing
import SocketIO
import BetterAuth
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
        #expect(socket.events.filter { $0.0 == "playbackStart" }.isEmpty)
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
            await reporter.update(paused); await reporter.update(track); await reporter.playbackStarted()
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

/// The realtime connection presents the session cookie it was built with; a replaced cookie (password change with
/// "Sign Out Other Devices", a new sign-in) must never leave it handshaking with the old one.
@MainActor
struct RealtimeSessionReplacementTests {
    private func cookies(_ token: String) throws -> [HTTPCookie] {
        let jar = CookieStorage(storage: MemoryCookieStorage())
        try jar.setCookie("__Secure-maple.session_token=\(token); Path=/; Secure; SameSite=None", for: MapleHTTP.baseURL)
        return (jar.cookies(for: MapleHTTP.baseURL) ?? [])
    }
    private func value(_ cookies: [HTTPCookie]) -> String? { cookies.first { $0.name == MapleHTTP.sessionCookieName }?.value }

    @Test func aReplacedCookieRebuildsTheConnectionAndTheSameCookieKeepsIt() throws {
        var opened: [SocketIOClient] = []
        let realtime = MapleRealtime(openSocket: { opened.append($0) })
        var disconnects = 0; realtime.onDisconnect = { disconnects += 1 }
        realtime.connect(cookies: try cookies("old"))
        let first = try #require(realtime.socket)
        realtime.connect(cookies: try cookies("old"))
        #expect(realtime.socket === first); #expect(opened.count == 1); #expect(disconnects == 0)
        realtime.connect(cookies: try cookies("new"))
        #expect(realtime.socket !== first); #expect(opened.count == 2); #expect(disconnects == 1)
        #expect(value(realtime.presentedCookies) == "new")
        realtime.disconnect()
        #expect(realtime.presentedCookies.isEmpty)
    }

    @Test func emptyCookiesNeverTearDownALiveConnection() throws {
        let realtime = MapleRealtime(openSocket: { _ in })
        realtime.connect(cookies: try cookies("old"))
        let socket = realtime.socket
        realtime.connect(cookies: [])
        #expect(realtime.socket === socket); #expect(value(realtime.presentedCookies) == "old")
        realtime.disconnect()
    }

    /// The reviewer's H2 sequence: the server ends the socket's session, the app revalidates (valid, with the new
    /// cookie in the jar) and must reconnect with that cookie rather than reopen the old socket.
    @Test func aServerDisconnectAfterACookieReplacementReconnectsWithTheCurrentCookie() async throws {
        let rebuilt = TestGate(); var opens = 0
        let realtime = MapleRealtime(openSocket: { _ in opens += 1; if opens == 2 { Task { await rebuilt.open() } } }, retrySleep: { _ in })
        var jar = try cookies("old")
        realtime.cookieProvider = { jar }
        realtime.connect(cookies: jar)
        let old = try #require(realtime.socket)
        realtime.validateSession = { .valid }
        jar = try cookies("new")                       // change-password stored the replacement cookie
        old.didDisconnect(reason: "Got Disconnect")     // the server ended the old session
        await rebuilt.wait()
        #expect(realtime.socket !== old); #expect(value(realtime.presentedCookies) == "new"); #expect(opens == 2)
        realtime.disconnect()
    }

    @Test func returningToTheForegroundPicksUpAReplacedCookie() throws {
        var opens = 0
        let realtime = MapleRealtime(openSocket: { _ in opens += 1 })
        var jar = try cookies("old")
        realtime.cookieProvider = { jar }
        realtime.connect(cookies: jar)
        let old = try #require(realtime.socket)
        old.didConnect(toNamespace: "/", payload: nil)
        jar = try cookies("new")
        realtime.sceneBecameActive()
        #expect(realtime.socket !== old); #expect(value(realtime.presentedCookies) == "new"); #expect(opens == 2)
        realtime.disconnect()
    }

    /// An authentication failure while the session is still valid is retried for as long as that stays true, with a
    /// growing pause, and a successful connection starts the count over.
    @Test func aRefusedHandshakeWithAValidSessionKeepsRetryingWithBackoff() async throws {
        let sleeper = TestSleeper(); var opens = 0; var validations = 0
        var reopened = TestGate()
        let realtime = MapleRealtime(openSocket: { _ in opens += 1; let gate = reopened; Task { await gate.open() } }, retrySleep: { try await sleeper.sleep($0) })
        let jar = try cookies("same")
        realtime.cookieProvider = { jar }
        realtime.connect(cookies: jar)
        let socket = try #require(realtime.socket)
        realtime.validateSession = { validations += 1; return .valid }
        func reject() { socket.handleClientEvent(.error, data: ["Authentication error: Invalid session"]) }

        reopened = TestGate(); reject(); await reopened.wait()           // first refusal: checked at once
        #expect(validations == 1); #expect(opens == 2); #expect(await sleeper.delays.isEmpty)
        reopened = TestGate(); reject()                                   // second: waits 5 s first
        await sleeper.waitForSleep(); #expect(validations == 1); await sleeper.advance(); await reopened.wait()
        #expect(validations == 2); #expect(opens == 3)
        reopened = TestGate(); reject()                                   // third: 10 s
        await sleeper.waitForSleep(); await sleeper.advance(); await reopened.wait()
        #expect(await sleeper.delays == [.seconds(5), .seconds(10)]); #expect(opens == 4)

        socket.didConnect(toNamespace: "/", payload: nil)                 // connected: the count starts over
        reopened = TestGate(); socket.didDisconnect(reason: "Got Disconnect"); await reopened.wait()
        #expect(await sleeper.delays.count == 2); #expect(validations == 4)
        realtime.disconnect()
    }

    @Test func aRefusedHandshakeForAnEndedSessionStopsRetrying() async throws {
        let validated = TestGate(); var validations = 0
        let realtime = MapleRealtime(openSocket: { _ in }, retrySleep: { _ in })
        realtime.connect(cookies: try cookies("gone"))
        let socket = try #require(realtime.socket)
        realtime.validateSession = { validations += 1; await validated.open(); return .invalid }
        socket.handleClientEvent(.error, data: ["Authentication error: Invalid session"])
        await validated.wait()
        #expect(validations == 1)
        realtime.disconnect()
    }

    /// The pieces the app wires together: a password change replaces the cookie, `didChange` runs `syncSocket`.
    @Test func changingThePasswordMovesTheLiveConnectionToTheNewCookie() async throws {
        let replacement: WireHarness.Route = { jar in
            try? jar.setCookie("__Secure-maple.session_token=new-session; Path=/; Max-Age=604800; Secure; HttpOnly; SameSite=None", for: MapleHTTP.baseURL)
            return StubReply(Wire.changePasswordReplaced)
        }
        let h = try WireHarness(token: "old-session", routes: ["POST /api/auth/change-password": replacement])
        let realtime = MapleRealtime(openSocket: { _ in })
        let http = h.http
        realtime.cookieProvider = { http.sessionCookies }
        h.auth.didChange = { realtime.connect(cookies: http.sessionCookies) }   // AppServices.sessionChanged → syncSocket
        realtime.connect(cookies: http.sessionCookies)
        let old = try #require(realtime.socket)
        #expect(value(realtime.presentedCookies) == "old-session")
        try await h.auth.changePassword(current: "OldPass123", new: "NewPass123", revokeOtherSessions: true)
        #expect(realtime.socket !== old); #expect(value(realtime.presentedCookies) == "new-session")
        realtime.disconnect()
    }
    /// Any authenticated HTTP route can refresh the cookie; AppServices wires this hook to syncSocket.
    @Test func aCookieChangedBySessionLookupImmediatelyRebuildsRealtime() async throws {
        let h = try WireHarness(token: "old-session", routes: ["GET /api/auth/get-session": { jar in
            try? jar.setCookie("__Secure-maple.session_token=new-session; Path=/; Secure", for: MapleHTTP.baseURL)
            return StubReply(Wire.getSession)
        }])
        let realtime = MapleRealtime(openSocket: { _ in })
        let http = h.http
        realtime.connect(cookies: http.sessionCookies)
        let old = try #require(realtime.socket)
        http.sessionChanged.set { _ in await realtime.connect(cookies: http.sessionCookies) }
        _ = try await h.auth.currentSession()
        #expect(realtime.socket !== old); #expect(value(realtime.presentedCookies) == "new-session")
        realtime.disconnect()
    }

}
