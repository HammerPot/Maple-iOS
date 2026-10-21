import Foundation
import SocketIO
import Testing
import UIKit
@testable import Maple

private final class LiveTestBundle: NSObject {}

/// Opt in with an ignored MapleLiveTestCredentials.json resource; never creates accounts.
@MainActor
struct MapleLiveTests {
    @Test(.enabled(if: Bundle(for: LiveTestBundle.self).url(forResource: "MapleLiveTestCredentials", withExtension: "json") != nil),
          .timeLimit(.minutes(3)))
    func authenticatedPlaybackLifecycle() async throws {
        let url = try #require(Bundle(for: LiveTestBundle.self).url(forResource: "MapleLiveTestCredentials", withExtension: "json"))
        let credentials = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String])
        let username = try #require(credentials["username"])
        let password = try #require(credentials["password"])
        let socketEnabled = UserDefaults.standard.bool(forKey: "socketIO")
        let discordEnabled = UserDefaults.standard.bool(forKey: "mapleRPC")
        UserDefaults.standard.set(true, forKey: "socketIO")
        UserDefaults.standard.set(true, forKey: "mapleRPC")
        defer {
            AppSocketManager.shared.disconnect()
            clearMapleSession()
            UserDefaults.standard.set(socketEnabled, forKey: "socketIO")
            UserDefaults.standard.set(discordEnabled, forKey: "mapleRPC")
        }
        let login = try await login(username: username, password: password)
        #expect(login.success)
        UserDefaults.standard.set(login.serverID, forKey: "savedServerID")
        let cookies = try #require(loadCookies())
        #expect(cookies.contains { $0.name == "token" && $0.isSecure == true })
        for cookie in HTTPCookieStorage.shared.cookies(for: MapleAPI.baseURL) ?? [] { HTTPCookieStorage.shared.deleteCookie(cookie) }
        restoreCookies(cookies)
        let user = try await getUser(serverID: login.serverID)
        #expect(user.username == username)
        _ = try await getPublicPfp(serverID: login.serverID)
        let (friends, _) = try await getFriendList(serverID: login.serverID)
        #expect(friends.isEmpty)
        let (requests, _) = try await getReqList(serverID: login.serverID)
        #expect(requests.isEmpty)
        _ = try await uploadName(serverID: login.serverID, name: "Maple iOS compatibility test")

        let observer = LiveRPCObserver()
        observer.socket.connect()
        defer { observer.manager.disconnect() }
        try await waitUntil { observer.generation != nil }
        var snapshot = MaplePlaybackSnapshot(trackID: "integration-track", source: "iOS", title: "Maple integration",
                                             artist: "Compatibility test", album: "Test album", playing: true, position: 5, duration: 180)
        let artwork = try #require(UIImage(named: "Maple")?.jpegData(compressionQuality: 0.5))
        let publisher = AppSocketManager.shared
        publisher.updatePlayback({ snapshot }, artwork: artwork, claim: true)
        try await waitUntil { observer.latest["title"] as? String == "Maple integration" && observer.latest["artworkReady"] as? Bool == true }
        #expect(observer.latest["position"] as? Double == 5)
        #expect(observer.latest["duration"] as? Double == 180)
        let initialArtwork = try #require(observer.latest["artworkRequestId"] as? String)

        snapshot = MaplePlaybackSnapshot(trackID: snapshot.trackID, source: "iOS", title: snapshot.title, artist: snapshot.artist,
                                         album: snapshot.album, playing: false, position: 5, duration: 180)
        publisher.updatePlayback({ snapshot }, claim: false)
        try await waitUntil { observer.latest["playing"] as? Bool == false }

        snapshot = MaplePlaybackSnapshot(trackID: "integration-track-2", source: "iOS", title: "Maple second track",
                                         artist: "Compatibility test", album: "Test album", playing: true, position: 70, duration: 180)
        publisher.updatePlayback({ snapshot }, artwork: artwork, claim: true)
        try await waitUntil { observer.latest["title"] as? String == "Maple second track" && observer.latest["artworkReady"] as? Bool == true }
        #expect(observer.latest["position"] as? Double == 70)
        #expect(observer.latest["artworkRequestId"] as? String != initialArtwork)

        // Keep the real heartbeat running, and require a fresh sampled position after 15 seconds.
        snapshot = MaplePlaybackSnapshot(trackID: snapshot.trackID, source: "iOS", title: snapshot.title, artist: snapshot.artist,
                                         album: snapshot.album, playing: true, position: 85, duration: 180)
        try await waitUntil { observer.latest["position"] as? Double == 85 }

        let generation = try #require(observer.generation)
        observer.socket.emit("playbackState", ["generation": generation, "claim": true, "playing": true, "discord": true,
                                                "title": "Other client", "artist": "Other artist", "album": "Other album", "position": 0])
        try await waitUntil { observer.latest["title"] as? String == "Other client" }
        publisher.refreshPlayback()
        try await Task.sleep(for: .seconds(1))
        #expect(observer.latest["title"] as? String == "Other client")
        snapshot = MaplePlaybackSnapshot(trackID: snapshot.trackID, source: "iOS", title: snapshot.title, artist: snapshot.artist,
                                         album: snapshot.album, playing: false, position: 85, duration: 180)
        publisher.updatePlayback({ snapshot }, claim: false)
        try await Task.sleep(for: .seconds(1))
        #expect(observer.latest["title"] as? String == "Other client")

        // A deliberate resume may reclaim, and turning off Discord must clear immediately.
        snapshot = MaplePlaybackSnapshot(trackID: snapshot.trackID, source: "iOS", title: snapshot.title, artist: snapshot.artist,
                                         album: snapshot.album, playing: true, position: 90, duration: 180)
        publisher.updatePlayback({ snapshot }, claim: true)
        try await waitUntil { observer.latest["position"] as? Double == 90 }
        UserDefaults.standard.set(false, forKey: "mapleRPC")
        publisher.settingsChanged()
        try await waitUntil { observer.latest["playing"] as? Bool == false }
        // Exercise the native AVAudioPlayer hooks as well as synthetic socket snapshots.
        UserDefaults.standard.set(true, forKey: "mapleRPC")
        let player = AudioPlayerManager.shared
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("tracks")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent(UUID().uuidString + ".wav")
        try silentWAV().write(to: audioURL)
        defer {
            player.stop()
            try? FileManager.default.removeItem(at: audioURL)
        }
        let song = Song(id: UUID(), title: "Native player integration", artist: "Compatibility test", album: "Test album",
                        year: 2026, genre: "Test", duration: 60, artwork: nil, trackNumber: 1, discNumber: 1, ext: "wav", url: audioURL)
        player.setQueue([song])
        player.play()
        try await waitUntil { observer.latest["title"] as? String == song.title }
        #expect(player.isPlaying)
        #expect(observer.latest["duration"] as? Double == 60)
        player.seek(to: 20)
        try await waitUntil { (observer.latest["position"] as? Double ?? 0) >= 20 }
        player.pause()
        try await waitUntil { observer.latest["playing"] as? Bool == false }
        player.play()
        try await waitUntil { observer.latest["playing"] as? Bool == true }
        player.stop()
        try await waitUntil { observer.latest["playing"] as? Bool == false }
        _ = try await uploadPfp(serverID: login.serverID, pfp: artwork)
        let profilePicture = try await getPublicPfp(serverID: login.serverID)
        #expect(profilePicture == artwork)
        try await logout()
        #expect(UserDefaults.standard.string(forKey: "savedServerID") == nil)
        #expect(loadCookies() == nil)
    }

    private func silentWAV() -> Data {
        let pcm = Data(repeating: 0, count: 60 * 8_000 * 2)
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + pcm.count))
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(8_000))
        append(UInt32(16_000))
        append(UInt16(2))
        append(UInt16(16))
        data.append(Data("data".utf8))
        append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        try #require(condition(), "Timed out waiting for the live Maple API")
    }
}

@MainActor
private final class LiveRPCObserver {
    let manager: SocketManager
    let socket: SocketIOClient
    var generation: String?
    var latest: [String: Any] = [:]

    init() {
        manager = SocketManager(socketURL: MapleAPI.baseURL, config: [.log(false), .cookies(HTTPCookieStorage.shared.cookies(for: MapleAPI.baseURL) ?? []), .handleQueue(.main)])
        socket = manager.defaultSocket
        socket.on("rpcOwnership") { [weak self] data, _ in
            self?.generation = (data.first as? [String: Any])?["generation"] as? String
        }
        socket.on("rpcUpdate") { [weak self] data, _ in self?.latest = data.first as? [String: Any] ?? [:] }
    }
}
