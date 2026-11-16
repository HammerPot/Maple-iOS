import Foundation
import Testing
import UIKit
@testable import Maple

/// Duplicate rules, album grouping, disc sections, durable playlist saves and artwork requests.
@MainActor
struct LibraryImportRulesTests {
    // MARK: §1.7 duplicates

    /// Untagged recordings that merely share the placeholder identity ("01" / Unknown Artist) are
    /// different songs unless their audio is the same.
    @Test func untaggedRecordingsWithTheSamePlaceholderIdentityAreNotDuplicates() async throws {
        let root = try makeTemporaryDirectory(), source = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        var fixtures: [String: ImportedAudio] = [:]
        let contents = [("01a.mp3", "aaaa"), ("01b.mp3", "bbbbbbbb"), ("01c.mp3", "aaaa")]
        for (name, content) in contents {
            try Data(content.utf8).write(to: source.appendingPathComponent(name))
            fixtures[name] = ImportedAudio(track: LibraryTrack(fileName: name, title: "01", duration: 30), artwork: nil, hasTitleAndArtist: false)
        }
        let store = LibraryStore(root: root, metadata: StubMetadataReader(fixtures: fixtures)); await store.load()
        let summary = await store.importFiles([source])
        // 01b differs in size and is kept; 01c has the size and length of 01a: the same recording again.
        #expect(summary.imported == 2); #expect(summary.duplicates == 1)
        #expect(store.tracks.count == 2)
    }

    @Test func taggedTitleAndArtistStillDetectDuplicatesRegardlessOfSize() async throws {
        let root = try makeTemporaryDirectory(), source = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let reader = StubMetadataReader(fixtures: [
            "x.mp3": ImportedAudio(track: LibraryTrack(fileName: "x.mp3", title: "Song", artist: "Artist"), artwork: nil),
            "y.mp3": ImportedAudio(track: LibraryTrack(fileName: "y.mp3", title: " song ", artist: "ARTIST"), artwork: nil)])
        try Data("short".utf8).write(to: source.appendingPathComponent("x.mp3"))
        try Data("a much longer file".utf8).write(to: source.appendingPathComponent("y.mp3"))
        let store = LibraryStore(root: root, metadata: reader); await store.load()
        let summary = await store.importFiles([source])
        #expect(summary.imported == 1); #expect(summary.duplicates == 1)
    }

    @Test func placeholderDetection() {
        for value in [nil, "", " ", "Unknown", "unknown artist", "<unknown>", "Untitled"] as [String?] { #expect(AudioMetadataReader.isPlaceholder(value)) }
        for value in ["Unknown Pleasures", "Beyoncé", "01"] { #expect(!AudioMetadataReader.isPlaceholder(value)) }
    }

    // MARK: §1.8 / §1.9 grouping

    private func track(_ title: String, artist: String, album: String, albumArtist: String? = nil, disc: Int = 0, number: Int = 0) -> LibraryTrack {
        LibraryTrack(fileName: "\(UUID().uuidString).mp3", title: title, artist: artist, album: album, albumArtist: albumArtist, trackNumber: number, discNumber: disc)
    }

    @Test func sameTitledAlbumsByDifferentArtistsStayApartWithoutAnAlbumArtistTag() {
        let tracks = [track("1", artist: "A", album: "Greatest Hits"), track("2", artist: "A", album: "Greatest Hits"),
                      track("3", artist: "B", album: "Greatest Hits")]
        let albums = LibraryGrouping.albums(from: tracks)
        #expect(albums.count == 2)
        #expect(albums.map(\.artist).sorted() == ["A", "B"])
        #expect(albums.first { $0.artist == "A" }?.trackIDs.count == 2)
    }

    @Test func compilationsShareAnAlbumThroughAnAlbumArtistAndMixedTaggingStillJoinsTheSameArtist() {
        let tracks = [track("1", artist: "C", album: "Now 99", albumArtist: "Various Artists"),
                      track("2", artist: "D", album: "Now 99", albumArtist: "Various Artists"),
                      track("3", artist: "One", album: "Mixed", albumArtist: "One"), track("4", artist: "One", album: "Mixed")]
        let albums = LibraryGrouping.albums(from: tracks)
        #expect(albums.count == 2)
        #expect(albums.first { $0.name == "Now 99" }?.trackIDs.count == 2)
        #expect(albums.first { $0.name == "Mixed" }?.trackIDs.count == 2)
    }

    @Test func compilationFlagBecomesVariousArtists() {
        #expect(AudioMetadataReader.compilationArtist("1") == "Various Artists")
        #expect(AudioMetadataReader.compilationArtist(" true ") == "Various Artists")
        #expect(AudioMetadataReader.compilationArtist("0") == nil); #expect(AudioMetadataReader.compilationArtist(nil) == nil)
    }

    @Test func equallyNamedAlbumsAndArtistsKeepOneOrderAcrossRebuilds() {
        let tracks = [track("1", artist: "A", album: "Twin"), track("2", artist: "B", album: "Twin"), track("3", artist: "C", album: "Twin")]
        let first = LibraryGrouping.albums(from: tracks).map(\.id)
        for _ in 0..<20 { #expect(LibraryGrouping.albums(from: tracks.shuffled()).map(\.id) == first) }
    }

    @Test func everyTrackOfAMultiDiscAlbumLandsInExactlyOneDiscSection() {
        let tracks = [track("a", artist: "X", album: "Y", disc: 1, number: 1), track("b", artist: "X", album: "Y", disc: 2, number: 1),
                      track("bonus", artist: "X", album: "Y", disc: 0, number: 0), track("c", artist: "X", album: "Y", disc: 1, number: 2)]
        let ordered = tracks.sorted(by: LibraryGrouping.albumOrder)
        let sections = LibraryGrouping.discSections(ordered)
        #expect(sections.map(\.disc) == [1, 2, 0])
        #expect(sections.flatMap(\.tracks).count == tracks.count)
        #expect(Set(sections.flatMap(\.tracks).map(\.id)) == Set(tracks.map(\.id)))
        // Descending order reverses the sections and what is inside them consistently.
        let reversed = LibraryGrouping.discSections(Array(ordered.reversed()))
        #expect(reversed.map(\.disc) == [0, 2, 1]); #expect(reversed.last?.tracks.map(\.title) == ["c", "a"])
    }

    // MARK: §1.10 durable saves

    private func persistedCatalog(_ root: URL) throws -> LibraryCatalog {
        try JSONDecoder().decode(LibraryCatalog.self, from: Data(contentsOf: root.appendingPathComponent("library/catalog.json")))
    }

    @Test func addTracksDurablyIsOnDiskWhenItReturns() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let tracks = [LibraryTrack(fileName: "a.mp3", title: "A"), LibraryTrack(fileName: "b.mp3", title: "B")]
        let disk = LibraryDisk(root: root); _ = try await disk.load()
        try await disk.save(LibraryCatalog(revision: 1, tracks: tracks))
        let store = LibraryStore(root: root); await store.load()
        let id = try store.createPlaylist(name: "Mix"); try await store.flush()
        let added = try await store.addTracksDurably(tracks.map(\.id), to: id)
        #expect(added == 2)
        // No waiting for the debounce: the catalog on disk already has the tracks.
        #expect(try persistedCatalog(root).playlists.first?.trackIDs == tracks.map(\.id))
    }

    @Test func addTracksDurablyReportsAFailedSaveInsteadOfSucceeding() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = FaultingFileSystem()
        let store = LibraryStore(root: root, fileSystem: fileSystem); await store.load()
        let id = try store.createPlaylist(name: "Mix"); try await store.flush()
        fileSystem.fail(.write, pathContaining: "catalog")
        var failed = false
        do { try await store.addTracksDurably([], to: id) } catch { failed = true }
        #expect(failed)
    }

    // MARK: §1.11 artwork requests

    private func writeImage(_ root: URL) throws -> URL {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        }
        let url = root.appendingPathComponent("cover.png")
        try #require(image.pngData()).write(to: url)
        return url
    }

    @Test func aCancelledThumbnailRequestPublishesNothing() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try writeImage(root)
        let cache = LibraryArtworkCache()
        let live = await cache.thumbnail(at: url, pixels: 64)
        #expect(live != nil)
        #expect(cache.cached(url, pixels: 64) != nil)
        let other = LibraryArtworkCache()
        let task = Task { @MainActor in await other.thumbnail(at: url, pixels: 64) }
        task.cancel() // the view's reference changed before the work started
        #expect(await task.value == nil)
        #expect(other.cached(url, pixels: 64) == nil)
    }

    @Test func thumbnailsAreBoundedToTheRequestedSize() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try writeImage(root)
        let image = try #require(await LibraryArtworkCache().thumbnail(at: url, pixels: 50))
        #expect(max(image.size.width, image.size.height) * image.scale <= 50.5)
    }
}
