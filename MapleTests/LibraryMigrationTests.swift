import Foundation
import Testing
@testable import Maple

/// Migration of the pre-rebuild JSON files (`tracks/tracks.json`, `albums/albums.json`,
/// `artists/artists.json`) into the catalog.
@MainActor
struct LibraryMigrationTests {
    private func prepare(_ root: URL, audio: [String] = [], images: [String] = []) throws {
        for folder in ["tracks", "images", "albums", "artists"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for name in audio { try Data("audio".utf8).write(to: root.appendingPathComponent("tracks/" + name)) }
        for name in images { try Data("image".utf8).write(to: root.appendingPathComponent("images/" + name)) }
    }
    private func row(_ id: UUID, _ title: String, file: String, artwork: String? = nil) -> String {
        let art = artwork.map { #","artwork":"\#($0)""# } ?? ""
        return #"{"id":"\#(id.uuidString)","title":"\#(title)","artist":"Artist","album":"Album","year":1999,"trackNumber":1,"discNumber":1,"ext":"mp3","url":"file:///var/mobile/Containers/Data/Application/OLD/Documents/tracks/\#(file)"\#(art)}"#
    }
    private func write(_ text: String, _ path: String, root: URL) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }

    /// §1.2: a scalar or null among the rows must not cost the valid rows around it.
    @Test func damagedRowsInTracksJSONDoNotDiscardTheValidOnes() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try prepare(root, audio: ["a.mp3", "b.mp3"], images: ["a.image"])
        let a = UUID(), b = UUID()
        try write("[\(row(a, "A", file: "a.mp3", artwork: "/images/a.image")), null, 7, \"text\", [], \(row(b, "B", file: "b.mp3"))]", "tracks/tracks.json", root: root)
        let store = LibraryStore(root: root); await store.load()
        #expect(store.isLoaded)
        #expect(Set(store.tracks.map(\.id)) == [a, b])
        #expect(store.track(a)?.artwork == "images/a.image")
        #expect(store.errorMessage != nil) // the user is told something could not be read
        let reopened = LibraryStore(root: root); await reopened.load()
        #expect(Set(reopened.tracks.map(\.id)) == [a, b])
    }

    @Test func damagedSongsInsideAlbumAndArtistSnapshotsAreSalvagedIndividually() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try prepare(root, audio: ["a.mp3", "b.mp3", "c.mp3"])
        let a = UUID(), b = UUID(), c = UUID()
        try write("broken", "tracks/tracks.json", root: root)
        try write("[{\"name\":\"X\",\"songs\":[\(row(a, "A", file: "a.mp3")), null, \(row(b, "B", file: "b.mp3"))]}, 5, {\"songs\":\"bad\"}]", "albums/albums.json", root: root)
        try write("[null,{\"name\":\"Y\",\"songs\":[1, \(row(c, "C", file: "c.mp3"))]}]", "artists/artists.json", root: root)
        let store = LibraryStore(root: root); await store.load()
        #expect(Set(store.tracks.map(\.id)) == [a, b, c])
    }

    /// A source that exists but cannot be read right now is not the same as a corrupt one:
    /// finishing the migration would make the loss permanent, so the library stays closed
    /// and the next launch retries.
    @Test func temporarilyUnreadableLegacySourceDoesNotFinalizeAnIncompleteMigration() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try prepare(root, audio: ["a.mp3"])
        let a = UUID()
        try write("[\(row(a, "A", file: "a.mp3"))]", "tracks/tracks.json", root: root)
        let fileSystem = FaultingFileSystem()
        fileSystem.fail(.read, pathContaining: "tracks.json")
        let failing = LibraryStore(root: root, fileSystem: fileSystem); await failing.load()
        #expect(!failing.isLoaded); #expect(failing.loadError != nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("library/catalog.json").path))
        let retry = LibraryStore(root: root); await retry.load()
        #expect(retry.tracks.map(\.id) == [a])
    }

    /// Legacy files are never modified or removed by migration; audio stays where it was.
    @Test func migrationLeavesLegacySourcesAndAudioUntouched() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try prepare(root, audio: ["a.mp3"])
        let json = "[\(row(UUID(), "A", file: "a.mp3")), null]"
        try write(json, "tracks/tracks.json", root: root)
        let store = LibraryStore(root: root); await store.load()
        #expect(try String(contentsOf: root.appendingPathComponent("tracks/tracks.json"), encoding: .utf8) == json)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("tracks/a.mp3").path))
    }

    @Test func escapedAndUnicodeFileNamesAndDictionaryEncodedURLsMigrate() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try prepare(root, audio: ["Café Song.mp3", "plain.mp3"])
        let a = UUID(), b = UUID()
        let escaped = #"{"id":"\#(a.uuidString)","title":"Café","url":"file:///old/Documents/tracks/Caf%C3%A9%20Song.mp3"}"#
        let dictionary = #"{"id":"\#(b.uuidString)","title":"Plain","url":{"relative":"file:///old/Documents/tracks/plain.mp3"}}"#
        try write("[\(escaped),\(dictionary)]", "tracks/tracks.json", root: root)
        let store = LibraryStore(root: root); await store.load()
        #expect(store.track(a)?.fileName == "Café Song.mp3"); #expect(store.track(b)?.fileName == "plain.mp3")
    }

    @Test func duplicateIDsAndDuplicateFilesAreSplitOrSkipped() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try prepare(root, audio: ["a.mp3", "b.mp3"])
        let id = UUID()
        try write("[\(row(id, "A", file: "a.mp3")),\(row(id, "B", file: "b.mp3")),\(row(UUID(), "A again", file: "a.mp3"))]", "tracks/tracks.json", root: root)
        let store = LibraryStore(root: root); await store.load()
        #expect(store.tracks.count == 2); #expect(Set(store.tracks.map(\.id)).count == 2)
        #expect(Set(store.tracks.map(\.fileName)) == ["a.mp3", "b.mp3"])
    }
}
