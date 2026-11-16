import Foundation
import Testing
import ImageIO
import UIKit
@testable import Maple

func requestBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var body = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        body.append(contentsOf: buffer.prefix(count))
    }
    return body
}

func fixtureImage(width: Int = 64, height: Int = 32, alpha: Bool = false) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: alpha ? 0.5 : 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}
func fixtureData(image: CGImage, type: String = "public.jpeg", properties: [CFString: Any] = [:], frames: Int = 1) throws -> Data {
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, type as CFString, frames, nil))
    for _ in 0..<frames { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

struct UploadImageTests {
    @Test func JPEGWithGPSIsReencodedWithoutPrivateMetadata() throws {
        let input = try fixtureData(image: fixtureImage(width: 2400, height: 1200), properties: [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 40.7, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 74.0, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:16 12:00:00"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Private owner"]])
        let source = try #require(CGImageSourceCreateWithData(input as CFData, nil))
        let before = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(before[kCGImagePropertyGPSDictionary] != nil)
        let upload = try UploadImage.prepare(input)
        #expect(upload.data != input); #expect(upload.data.count <= UploadImage.maxBytes)
        let output = try #require(CGImageSourceCreateWithData(upload.data as CFData, nil))
        let after = try #require(CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any])
        #expect(after[kCGImagePropertyGPSDictionary] == nil)
        let exif = after[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = after[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil)
        #expect(tiff?[kCGImagePropertyTIFFArtist] == nil)
        #expect((after[kCGImagePropertyPixelWidth] as? Int ?? 9999) <= 1600)
    }
    @Test func transparentPNGPreservesAlphaAndRemovesMetadata() throws {
        let input = try fixtureData(image: fixtureImage(alpha: true), type: "public.png", properties: [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 40.7]])
        let upload = try UploadImage.prepare(input)
        #expect(upload.mime == "image/png"); #expect(upload.ext == "png")
        let source = try #require(CGImageSourceCreateWithData(upload.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect([CGImageAlphaInfo.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
    }
    @Test func animatedGIFFlattensToStillAndInvalidDataThrows() throws {
        let input = try fixtureData(image: fixtureImage(), type: "com.compuserve.gif", properties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]], frames: 2)
        let original = try #require(CGImageSourceCreateWithData(input as CFData, nil))
        #expect(CGImageSourceGetCount(original) == 2)
        let upload = try UploadImage.prepare(input)
        let source = try #require(CGImageSourceCreateWithData(upload.data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 1); #expect(upload.mime != "image/gif")
        #expect(throws: (any Error).self) { try UploadImage.prepare(Data("invalid".utf8)) }
    }
    @Test func multipartUsesPreparedImageAndPlaybackID() async throws {
        let received = Locked<URLRequest?>(nil); let body = Locked(Data())
        let http = try testHTTP { request in
            received.update { $0 = request }; body.update { $0 = requestBody(request) }
            return StubReply(#"{"message":"ok"}"#)
        }
        let input = try fixtureData(image: fixtureImage(alpha: true), type: "public.png")
        try await MapleAPI(http: http).setAlbumArt(input, playbackId: "playback-test")
        let text = String(decoding: body.read(), as: UTF8.self)
        #expect(text.contains("name=\"albumArt\"")); #expect(text.contains("filename=\"image.png\""))
        #expect(text.contains("name=\"playbackId\"\r\n\r\nplayback-test"))
        #expect(received.read()?.value(forHTTPHeaderField: "Origin") == MapleHTTP.origin)
    }
}

@MainActor
struct FriendsRefreshTests {
    @Test(arguments: [false, true]) func listeningStreamDoesNotLoopOrOverwriteLiveState(_ privateListening: Bool) async throws {
        let modelBox = Locked<FriendsModel?>(nil); let calls = Locked(0)
        let live = Listening(current: CurrentPlayback(title: "Live", artist: "Artist", album: "Album", duration: 100, playing: true, position: 12, playbackRate: 1, artwork: nil), lastPlayed: nil)
        let http = try testHTTP { request in
            if request.url?.path.hasSuffix("requests") == true { return StubReply(#"{"incoming":[],"outgoing":[]}"#) }
            let count = calls.update { $0 += 1; return $0 }
            guard count <= 3 else { throw URLError(.resourceUnavailable) }
            // Every HTTP snapshot is stale relative to a real asynchronous stream of listening events.
            for _ in 0..<40 {
                await MainActor.run { modelBox.read()?.listening(ListeningEvent(id: "friend", listening: privateListening ? nil : live)) }
            }
            return StubReply(#"[{"id":"friend","username":"friend","name":null,"listening":{"current":null,"lastPlayed":null}}]"#)
        }
        let model = FriendsModel(api: MapleAPI(http: http)); modelBox.update { $0 = model }
        try await model.refresh()
        #expect(calls.read() == 1); #expect(model.friends.count == 1)
        #expect(model.friends.first?.listening == (privateListening ? nil : live))
        model.clear(); #expect(model.friends.isEmpty)
    }
    @Test func friendshipEventsAreBoundedAndSignOutClearsLastEvent() async throws {
        let http = try testHTTP { request in
            StubReply(request.url?.path.hasSuffix("requests") == true ? #"{"incoming":[],"outgoing":[]}"# : "[]")
        }
        let model = FriendsModel(api: MapleAPI(http: http))
        try await model.friendship("friendRequest", event: FriendshipEvent(id: "friend", message: nil))
        #expect(model.lastEvent == "friendRequest")
        model.clear(); #expect(model.lastEvent == nil)
    }
}

struct WebhookReporterTests {
    private var track: TrackSnapshot { track("Track") }
    private func track(_ title: String) -> TrackSnapshot {
        TrackSnapshot(identity: "local:" + title, title: title, artist: "Artist", album: "Album", duration: 100, playing: true, position: 0)
    }
    @Test func rapidSkipsCoalesceToOnePostForTheNewestTrack() async throws {
        let requests = Locked<[URLRequest]>([]); let bodies = Locked<[String]>([]); let time = Locked<TimeInterval>(0)
        let sleeper = TestSleeper()
        let config = StubURLProtocol.configuration { request in
            requests.update { $0.append(request) }
            bodies.update { $0.append(String(decoding: requestBody(request), as: UTF8.self)) }
            return StubReply(status: 204)
        }
        let reporter = WebhookReporter(session: URLSession(configuration: config), minimumInterval: 10,
            configuredURL: { "https://discord.example.test/webhook" }, now: { time.read() }, sleep: { try await sleeper.sleep($0) })
        try await reporter.send(track: track("First"), artwork: nil, userID: "user")
        #expect(requests.read().count == 1)
        // Twenty skips 4 s later: all wait for the window, none posts yet.
        time.update { $0 = 4 }
        var skips: [Task<Void, Error>] = []
        for index in 0..<20 {
            let skip = track("Skip \(index)")
            skips.append(Task { try await reporter.send(track: skip, artwork: nil, userID: "user") })
            await sleeper.waitForSleeps(index + 1)
        }
        #expect(requests.read().count == 1)
        #expect(await sleeper.delays.allSatisfy { $0 == .seconds(6) })
        time.update { $0 = 10 }
        await sleeper.advance()
        for skip in skips { try await skip.value }
        #expect(requests.read().count == 2)
        let last = try #require(bodies.read().last)
        #expect(last.contains("Skip 19")); #expect(!last.contains("Skip 18"))
        // After the window, a single change posts immediately.
        time.update { $0 = 25 }
        try await reporter.send(track: track("Later"), artwork: nil, userID: "user")
        #expect(requests.read().count == 3)
        #expect(requests.read().allSatisfy { $0.value(forHTTPHeaderField: "Origin") == nil && $0.value(forHTTPHeaderField: "Cookie") == nil })
    }
    @Test func invalidArtworkStillPostsWithoutAttachmentOrOrigin() async throws {
        let received = Locked<URLRequest?>(nil); let body = Locked(Data())
        let session = URLSession(configuration: StubURLProtocol.configuration { request in
            received.update { $0 = request }; body.update { $0 = requestBody(request) }; return StubReply(status: 204)
        })
        let reporter = WebhookReporter(session: session, configuredURL: { "https://discord.example.test/webhook" })
        try await reporter.send(track: track, artwork: Data("broken artwork".utf8), userID: "user")
        #expect(received.read() != nil); #expect(received.read()?.value(forHTTPHeaderField: "Origin") == nil)
        let text = String(decoding: body.read(), as: UTF8.self)
        #expect(text.contains("payload_json")); #expect(text.contains("Track"))
        #expect(!text.contains("files[0]")); #expect(!text.contains("attachment://"))
    }
    @Test func PNGAttachmentNameAndMIMEAgree() async throws {
        let body = Locked(Data())
        let session = URLSession(configuration: StubURLProtocol.configuration { request in body.update { $0 = requestBody(request) }; return StubReply(status: 204) })
        let reporter = WebhookReporter(session: session, configuredURL: { "https://discord.example.test/webhook" })
        let png = try fixtureData(image: fixtureImage(alpha: true), type: "public.png")
        try await reporter.send(track: track, artwork: png, userID: "user")
        let text = String(decoding: body.read(), as: UTF8.self)
        #expect(text.contains("artwork.png")); #expect(text.contains("image/png"))
    }
}
