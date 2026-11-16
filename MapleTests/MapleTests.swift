import Foundation
import Testing
@testable import Maple

struct MapleModelTests {
    @Test func currentUserAndListeningDecode() throws {
        let json = #"{"id":"0123456789abcdef0123456789abcdef","username":"test","name":null,"pfp":"AQID","listeningVisibility":"public","listening":{"current":{"title":"Track","artist":"Artist","album":"Album","duration":120.5,"playing":true,"position":15.75,"playbackRate":1.25,"artwork":"cover-id"},"lastPlayed":{"title":"Previous","artist":"Artist","album":"Album","duration":null,"playedAt":"2026-11-16T18:00:00.123Z","artwork":null}}}"#
        let user = try JSONDecoder.maple.decode(MapleUser.self, from: Data(json.utf8))
        #expect(user.name == nil)
        #expect(user.pfp == Data([1, 2, 3]))
        #expect(user.listening.current?.position == 15.75)
        #expect(user.listening.lastPlayed?.playedAt != nil)
        #expect(user.profile.label == "test")
    }
    @Test func privateFriendAndRequestsDecode() throws {
        let json = #"[{"id":"legacy-id","username":"friend","name":"Friend","listening":null}]"#
        let friends = try JSONDecoder.maple.decode([ListeningProfile].self, from: Data(json.utf8))
        #expect(friends.first?.listening == nil)
        let requests = try JSONDecoder.maple.decode(FriendRequests.self, from: Data(#"{"incoming":[{"id":"123","username":"request","name":null}],"outgoing":[]}"#.utf8))
        #expect(requests.incoming.first?.label == "request")
        #expect(requests.outgoing.isEmpty)
    }
    @Test(arguments: ["2026-11-16T18:00:00Z", "2026-11-16T18:00:00.123Z"])
    func authSessionDatesDecode(_ timestamp: String) throws {
        let json = """
        {"id":"session","token":"test-only-token","userId":"user","expiresAt":"\(timestamp)","createdAt":"\(timestamp)","updatedAt":"\(timestamp)","ipAddress":null,"userAgent":null}
        """
        let session = try JSONDecoder.maple.decode(AuthSession.self, from: Data(json.utf8))
        #expect(session.id == "session")
    }
    @Test func errorShapesRetainStatusAndCode() {
        let auth = MapleError.response(status: 403, data: Data(#"{"code":"EMAIL_NOT_VERIFIED","message":"Email is not verified"}"#.utf8))
        #expect(auth.status == 403)
        #expect(auth.code == "EMAIL_NOT_VERIFIED")
        #expect(auth.localizedDescription.contains("browser"))
        let rest = MapleError.response(status: 409, data: Data(#"{"error":"Playback is no longer current."}"#.utf8))
        #expect(rest.error == "Playback is no longer current.")
        #expect(rest.localizedDescription == "Playback is no longer current.")
        #expect(MapleError.response(status: 401, data: Data("Unauthorized".utf8)).localizedDescription.contains("sign in"))
        #expect(MapleError(status: 429).localizedDescription.contains("wait"))
    }
    @Test func friendshipAndOwnershipEventsDecode() throws {
        let event = try JSONDecoder.maple.decode(PlaybackOwnershipEvent.self, from: Data(#"{"playbackId":null}"#.utf8))
        #expect(event.playbackId == nil)
        let event2 = try JSONDecoder.maple.decode(FriendshipEvent.self, from: Data(#"{"id":"friend"}"#.utf8))
        #expect(event2.message == nil)
        let rpc = try JSONDecoder.maple.decode(RPCUpdate.self, from: Data(#"{"playing":false}"#.utf8))
        #expect(!rpc.playing)
    }
}

@MainActor
private final class FakePlaybackTransport: PlaybackTransport {
    var connected = true
    var events: [(String, PlaybackPayload)] = []
    var response = PlaybackReply(ok: true, error: nil)
    var ownership: ((String?) -> Void)?
    var pendingStart: CheckedContinuation<PlaybackReply?, Never>?
    var suspendStart = false
    func send(_ event: String, payload: PlaybackPayload) async -> PlaybackReply? {
        guard connected else { return nil }
        events.append((event, payload))
        if event == "playbackStart" {
            ownership?(payload.playbackId)
            if suspendStart { return await withCheckedContinuation { pendingStart = $0 } }
        }
        return response
    }
}

@MainActor
struct PlaybackReporterTests {
    private var track: TrackSnapshot { TrackSnapshot(identity: "local:1", title: " Track ", artist: "Artist", album: "Album", duration: 100, playing: true, position: 0) }
    private func make(_ transport: FakePlaybackTransport) -> PlaybackReporter {
        let reporter = PlaybackReporter(transport: transport, automaticHeartbeat: false, discord: { true })
        transport.ownership = { [weak reporter] in reporter?.ownershipChanged($0) }
        return reporter
    }
    @Test func startUpdatePauseSeekRateAndStop() async throws {
        let socket = FakePlaybackTransport(); let reporter = make(socket)
        await reporter.update(track)
        let id = try #require(reporter.playbackId)
        #expect(reporter.ownsPlayback)
        #expect(socket.events.map(\.0) == ["playbackStart", "playbackUpdate"])
        #expect(socket.events[0].1.title == "Track")
        var paused = track; paused.playing = false; paused.position = 20; paused.playbackRate = 1.5
        await reporter.update(paused)
        #expect(socket.events.last?.1.playing == false)
        #expect(socket.events.last?.1.position == 20)
        #expect(socket.events.last?.1.playbackRate == 1.5)
        #expect(socket.events.last?.1.discord == true)
        #expect(socket.events.last?.1.playbackId == id)
        await reporter.stop()
        #expect(socket.events.last?.0 == "playbackStop")
        #expect(reporter.playbackId == nil)
        #expect(!reporter.ownsPlayback)
    }
    @Test func smallExplicitSeekIsReported() async {
        let socket = FakePlaybackTransport(); let reporter = make(socket)
        await reporter.update(track)
        var seek = track; seek.position = 1
        await reporter.update(seek, force: true)
        #expect(socket.events.last?.1.position == 1)
    }
    @Test func heartbeatUsesFreshPosition() async {
        let socket = FakePlaybackTransport(); let reporter = make(socket)
        await reporter.update(track)
        var fresh = track; fresh.position = 25
        reporter.snapshotProvider = { fresh }
        await reporter.sendUpdate()
        #expect(socket.events.last?.1.position == 25)
        #expect(socket.events.last?.0 == "playbackUpdate")
    }
    @Test func ownershipLossAndReconnectDoNotReclaim() async {
        let socket = FakePlaybackTransport(); let reporter = make(socket)
        await reporter.update(track)
        reporter.ownershipChanged("another-device")
        #expect(!reporter.ownsPlayback)
        let count = socket.events.count
        var paused = track; paused.playing = false
        await reporter.update(paused); await reporter.sendUpdate()
        reporter.disconnected(); await reporter.connected()
        #expect(socket.events.count == count)
    }
    @Test func rejectedUpdateReleasesLease() async {
        let socket = FakePlaybackTransport(); let reporter = make(socket)
        await reporter.update(track)
        socket.response = PlaybackReply(ok: false, error: "Playback is no longer current.")
        await reporter.sendUpdate()
        #expect(!reporter.ownsPlayback)
    }
    @Test func rejectedStartDoesNotOwn() async {
        let socket = FakePlaybackTransport(); let reporter = make(socket)
        socket.response = PlaybackReply(ok: false, error: "Invalid playback.")
        await reporter.update(track)
        #expect(!reporter.ownsPlayback)
        #expect(socket.events.count == 1)
    }
    @Test func stoppedDuringStartAckCannotRegainOwnership() async {
        let socket = FakePlaybackTransport(); let reporter = make(socket)
        socket.suspendStart = true
        let start = Task { await reporter.update(track) }
        while socket.pendingStart == nil { await Task.yield() }
        await reporter.stop()
        socket.pendingStart?.resume(returning: PlaybackReply(ok: true, error: nil))
        await start.value
        #expect(!reporter.ownsPlayback)
        #expect(reporter.playbackId == nil)
        #expect(socket.events.map(\.0) == ["playbackStart", "playbackStop"])
    }
    @Test func inputSanitizationAndExplicitNullDuration() async throws {
        let socket = FakePlaybackTransport(); let reporter = make(socket)
        var value = track; value.position = .infinity; value.duration = -10; value.playbackRate = 99
        await reporter.update(value)
        let payload = try #require(socket.events.first?.1)
        #expect(payload.position == 0); #expect(payload.playbackRate == 16)
        let encoded = try JSONEncoder().encode(payload)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["duration"] is NSNull)
    }
    @Test func waitsForInitialConnection() async {
        let socket = FakePlaybackTransport(); socket.connected = false
        let reporter = make(socket)
        await reporter.update(track)
        #expect(socket.events.isEmpty)
        socket.connected = true
        await reporter.connected()
        #expect(reporter.ownsPlayback)
    }
}
