import Foundation
import Testing
@testable import Maple

/// Hostile or merely enormous tags must neither exhaust memory nor block an otherwise playable
/// file. The files below are hand-built ID3v2.3 tags; no audio frames are needed because only
/// the tag reader is under test.
struct LibraryResourceLimitTests {
    private func frame(_ id: String, _ body: [UInt8]) -> [UInt8] {
        let size = UInt32(body.count)
        return Array(id.utf8) + [UInt8(size >> 24 & 0xff), UInt8(size >> 16 & 0xff), UInt8(size >> 8 & 0xff), UInt8(size & 0xff), 0, 0] + body
    }
    private func text(_ id: String, _ value: String) -> [UInt8] { frame(id, [0] + Array(value.utf8)) }
    private func picture(_ bytes: Int) -> [UInt8] {
        frame("APIC", [0] + Array("image/jpeg".utf8) + [0, 3, 0] + [UInt8](repeating: 0x42, count: bytes))
    }
    private func lyrics(_ value: String) -> [UInt8] { frame("USLT", [0] + Array("eng".utf8) + [0] + Array(value.utf8)) }
    /// Writes `<ID3 header><frames>` and returns the file.
    private func file(frames: [[UInt8]], claimedTagSize: Int? = nil) throws -> URL {
        let body = frames.flatMap { $0 }
        let size = claimedTagSize ?? body.count
        let header: [UInt8] = Array("ID3".utf8) + [3, 0, 0, UInt8(size >> 21 & 0x7f), UInt8(size >> 14 & 0x7f), UInt8(size >> 7 & 0x7f), UInt8(size & 0x7f)]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp3")
        try Data(header + body).write(to: url)
        return url
    }
    private func tags(_ frames: [[UInt8]], claimedTagSize: Int? = nil) throws -> [String: Any] {
        let url = try file(frames: frames, claimedTagSize: claimedTagSize)
        defer { try? FileManager.default.removeItem(at: url) }
        return AudioMetadataReader.rawTags(at: url)
    }

    @Test func harnessReadsATitleAndAReasonablePicture() throws {
        let result = try tags([text("TIT2", "Hello"), picture(1000)])
        #expect(result["TITLE"] as? String == "Hello")
        #expect((result["artwork"] as? Data)?.count == 1000)
    }

    @Test func anOversizedPictureIsIgnoredButTheTagsAreStillRead() throws {
        let result = try tags([text("TIT2", "Big cover"), picture(LibraryLimits.maximumArtworkBytes + 1)])
        #expect(result["TITLE"] as? String == "Big cover")
        #expect(result["artwork"] == nil)
    }

    @Test func manyPicturesAreNotMaterialised() throws {
        let result = try tags([text("TIT2", "Many")] + (0..<40).map { _ in picture(100) })
        #expect(result["TITLE"] as? String == "Many")
        #expect(result["artwork"] == nil)
    }

    @Test func textAndLyricsAreTruncated() throws {
        let result = try tags([text("TIT2", String(repeating: "t", count: 100_000)), lyrics(String(repeating: "l", count: 1_000_000))])
        #expect((result["TITLE"] as? String)?.count == 4096)
        let lyricsText = try #require((result["LYRICS"] as? String) ?? (result.first { $0.key.hasPrefix("LYRICS") }?.value as? String))
        #expect(lyricsText.count <= 256 * 1024)
    }

    @Test func aTagClaimingToBeHugeIsNotParsed() throws {
        let result = try tags([text("TIT2", "Never read")], claimedTagSize: 200 * 1024 * 1024)
        #expect(result.isEmpty)
    }

    @Test func truncatedAndGarbageTagsReturnNothingInsteadOfCrashing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(Array("ID3".utf8) + [3, 0, 0, 0, 0, 1, 0] + [0x54, 0x49, 0x54, 0x32, 0x7f, 0xff, 0xff, 0xff]).write(to: url)
        _ = AudioMetadataReader.rawTags(at: url) // must return, whatever it contains
        try Data((0..<512).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: url)
        _ = AudioMetadataReader.rawTags(at: url)
    }

    @MainActor @Test func pictureBytesAboveTheLimitNeverReachDisk() async throws {
        let big = Data(count: LibraryLimits.maximumArtworkBytes + 1)
        let root = try makeTemporaryDirectory(), source = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        try Data("audio".utf8).write(to: source.appendingPathComponent("a.mp3"))
        let reader = StubMetadataReader(fixtures: ["a.mp3": ImportedAudio(track: LibraryTrack(fileName: "a.mp3", title: "A"), artwork: big)])
        let store = LibraryStore(root: root, metadata: reader); await store.load()
        let summary = await store.importFiles([source])
        #expect(summary.imported == 1)
        #expect(store.tracks.first?.artwork == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("images").path).isEmpty)
    }
}
