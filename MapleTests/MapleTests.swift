import Foundation
import Testing
@testable import Maple

struct MapleRPCTests {
    @Test func claimWaitsForOwnershipAndUsesFreshGeneration() {
        var ownership = MapleRPCOwnership()
        ownership.queueClaim(true)
        #expect(ownership.generation == nil)
        #expect(ownership.receive(generation: "initial", owned: false) == true)
        #expect(ownership.generation == "initial")
        #expect(ownership.pendingClaim == false)
        #expect(ownership.receive(generation: "claimed", owned: true) == false)
        #expect(ownership.generation == "claimed")
    }

    @Test func anotherClientTakingOwnershipDoesNotReclaim() {
        var ownership = MapleRPCOwnership()
        _ = ownership.receive(generation: "ours", owned: true)
        #expect(ownership.receive(generation: "theirs", owned: false) == nil)
        #expect(ownership.generation == "theirs")
        #expect(ownership.receive(generation: "theirs", owned: false) == nil)
    }

    @Test(arguments: ["", String(repeating: "a", count: 129)])
    func invalidOwnershipIsIgnored(generation: String) {
        var ownership = MapleRPCOwnership()
        ownership.queueClaim(true)
        #expect(ownership.receive(generation: generation, owned: true) == nil)
        #expect(ownership.generation == nil)
        #expect(ownership.pendingClaim == true)
    }

    @Test func disconnectDropsOldOwnershipAndPendingClaims() {
        var ownership = MapleRPCOwnership()
        _ = ownership.receive(generation: "old-account", owned: true)
        ownership.queueClaim(true)
        ownership.reset()
        #expect(ownership.generation == nil)
        #expect(ownership.pendingClaim == false)
        #expect(ownership.receive(generation: "new-account", owned: false) == nil)
    }

    @Test(arguments: [Double.nan, Double.infinity, -10])
    func invalidTimingNeverProducesInvalidJSON(position: Double) throws {
        let snapshot = MaplePlaybackSnapshot(trackID: "track", source: "iOS", title: "Title", artist: "Artist", album: "Album",
                                             playing: true, position: position, duration: .infinity, playbackRate: .nan)
        let payload = snapshot.payload(discord: true)
        #expect(payload["position"] as? Double == 0)
        #expect(payload["duration"] == nil)
        #expect(payload["playbackRate"] as? Double == 1)
        #expect(throws: Never.self) { _ = try JSONSerialization.data(withJSONObject: payload) }
    }

    @Test(arguments: [false, true])
    func pauseAndPlayingAreExplicit(playing: Bool) {
        let payload = MaplePlaybackSnapshot(trackID: "track", source: "iOS", title: "Title", artist: "Artist", album: "Album",
                                            playing: playing, position: 12, duration: 60).payload(discord: true)
        #expect(payload["playing"] as? Bool == playing)
        #expect(payload["position"] as? Double == 12)
        #expect(payload["duration"] as? Double == 60)
        #expect(payload["discord"] as? Bool == true)
    }

    @Test func endedTrackClearsRatherThanExtendingPresence() {
        let payload = MaplePlaybackSnapshot(trackID: "track", source: "iOS", title: "Title", artist: "Artist", album: "Album",
                                            playing: true, position: 60, duration: 60).payload(discord: true)
        #expect(payload["playing"] as? Bool == false)
    }
}

struct MapleAPITests {
    private func client() -> MapleAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MapleTestURLProtocol.self]
        return MapleAPI(baseURL: URL(string: "https://maple.invalid")!, session: URLSession(configuration: configuration))
    }

    @Test func serverJSONErrorIsPreserved() async throws {
        await #expect(throws: MapleAPIError.self) { try await client().request(["conflict"]) }
        do {
            _ = try await client().request(["conflict"])
        } catch let error as MapleAPIError {
            #expect(error.statusCode == 409)
            #expect(error.message == "Friend request already sent/pending.")
        }
    }

    @Test(arguments: [401, 403, 429, 500])
    func plainTextHTTPFailuresAreErrors(status: Int) async throws {
        do {
            _ = try await client().request([String(status)])
            Issue.record("HTTP failure was accepted as success")
        } catch let error as MapleAPIError {
            #expect(error.statusCode == status)
            #expect(error.message.isEmpty == false)
        }
    }

    @Test func missingPictureIsOptionalButMissingUserFails() async throws {
        let api = client()
        let picture = try await api.request(["404"], allowMissing: true)
        #expect(picture.isEmpty)
        await #expect(throws: MapleAPIError.self) { try await api.request(["404"]) }
    }

    @Test(arguments: ["a name?#", "a/name", "user%20name"])
    func JSONRequestAndPathComponentsAreEncoded(username: String) async throws {
        let data = try await client().request(["public", "get", "user", username], method: "POST", json: ["displayName": "Maple 🍁"])
        let echo = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(echo["method"] as? String == "POST")
        #expect(echo["contentType"] as? String == "application/json")
        let urlString = try #require(echo["url"] as? String)
        let url = try #require(URL(string: urlString))
        #expect(url.lastPathComponent == username)
        #expect(url.query == nil)
        #expect(url.fragment == nil)
        let body = try #require((echo["body"] as? String)?.data(using: .utf8))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["displayName"] == "Maple 🍁")
    }

    @Test func artworkUploadCorrelatesRequestAndActualImageType() async throws {
        let image = Data([0x89, 0x50, 0x4E, 0x47])
        let data = try await client().upload(["user", "manage", "setAlbumArt", "account"], field: "albumArt", image: image, artworkRequestId: "track-request")
        let echo = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(echo["method"] as? String == "POST")
        let body = try #require(echo["body"] as? String)
        #expect(body.contains("name=\"albumArt\""))
        #expect(body.contains("Content-Type: image/png"))
        #expect(body.contains("name=\"artworkRequestId\"\r\n\r\ntrack-request"))
        #expect((echo["contentType"] as? String)?.hasPrefix("multipart/form-data; boundary=") == true)
    }
}

/// Stateless fixture: each request determines its own response, so tests can run in parallel.
private final class MapleTestURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let component = request.url!.lastPathComponent
        let status = component == "conflict" ? 409 : (Int(component) ?? 200)
        let data: Data
        if component == "conflict" {
            data = Data(#"{"error":"Friend request already sent/pending."}"#.utf8)
        } else if status >= 400 {
            data = Data("Unauthorized".utf8)
        } else {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            data = try! JSONSerialization.data(withJSONObject: ["url": request.url!.absoluteString,
                "method": request.httpMethod ?? "", "contentType": request.value(forHTTPHeaderField: "Content-Type") ?? "",
                "body": String(decoding: body, as: UTF8.self)])
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
