import Foundation
import Testing
@testable import Maple

private final class LibraryFixtureBundle: NSObject { }

struct LibraryMetadataTests {
    private func fixture(_ name: String) throws -> URL {
        let bundle = Bundle(for: LibraryFixtureBundle.self)
        let file = URL(fileURLWithPath: name)
        return try #require(bundle.url(forResource: file.deletingPathExtension().lastPathComponent, withExtension: file.pathExtension))
    }
    @Test(arguments: ["tags23.mp3", "tags24.mp3", "tags.m4a", "lossless.m4a", "tags.flac", "tags.aiff", "tags.wav", "tags.aac", "tags.caf", "missing.wav"])
    func nativeDecoderAcceptsFixtures(_ name: String) async throws {
        let audio = try await AudioMetadataReader().read(fixture(name))
        #expect(audio.track.duration > 0.4)
    }
    @Test(arguments: ["tags23.mp3", "tags24.mp3", "tags.m4a", "lossless.m4a", "tags.flac"])
    func taggedFixturesRetainMetadata(_ name: String) async throws {
        let audio = try await AudioMetadataReader().read(fixture(name))
        #expect(audio.track.title == "Fixture Song")
        #expect(audio.track.artist == "Fixture Artist")
        #expect(audio.track.album == "Fixture Album")
        #expect(audio.track.albumArtist == "Fixture Album Artist")
        #expect(audio.track.year == 2024)
        #expect(audio.track.genre == "Jazz")
        #expect(audio.track.trackNumber == 3)
        #expect(audio.track.discNumber == 2)
        #expect(audio.track.lyrics?.contains("First line") == true)
    }
    @Test(arguments: ["artwork.mp3", "artwork.flac", "artwork.m4a"])
    func embeddedArtworkIsRead(_ name: String) async throws {
        let audio = try await AudioMetadataReader().read(fixture(name))
        #expect((audio.artwork?.count ?? 0) > 50)
    }
    @Test func plainAndSynchronizedID3LyricsArePreserved() async throws {
        let reader = AudioMetadataReader()
        let plain = try await reader.read(fixture("plain-lyrics.mp3"))
        let synced = try await reader.read(fixture("synced-lyrics.mp3"))
        #expect(plain.track.lyrics == "Plain embedded lyrics")
        #expect(synced.track.lyrics?.contains("[00:00.100]First synced line") == true)
        #expect(synced.track.lyrics?.contains("[00:00.400]Second synced line") == true)
    }
}
