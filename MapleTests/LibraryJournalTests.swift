import Foundation
import Testing
@testable import Maple

/// The deletion journal (`pendingFileRemovals`) must never delete a file a live track or
/// playlist still references, whatever happened to earlier operations.
@MainActor
struct LibraryJournalTests {
    private func fixture(_ file: String, title: String, cover: Data?) -> (String, ImportedAudio) {
        (file, ImportedAudio(track: LibraryTrack(fileName: file, title: title, artist: "Artist \(title)"), artwork: cover))
    }
    private func exists(_ root: URL, _ reference: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(reference).path)
    }
    private func persistedCatalog(_ root: URL) throws -> LibraryCatalog {
        try JSONDecoder().decode(LibraryCatalog.self, from: Data(contentsOf: root.appendingPathComponent("library/catalog.json")))
    }

    /// §1.1: the deletion's journal write fails (full disk), the user keeps using the app and
    /// imports a track with the same cover; the journal entry must not survive into a relaunch.
    @Test func failedDeletionJournalNeverRemovesArtworkThatWasReused() async throws {
        let root = try makeTemporaryDirectory(), source = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let cover = Data("shared cover".utf8)
        let a = fixture("a.mp3", title: "A", cover: cover), b = fixture("b.mp3", title: "B", cover: cover)
        let reader = StubMetadataReader(fixtures: [a.0: a.1, b.0: b.1])
        for name in ["a.mp3", "b.mp3"] { try Data("audio".utf8).write(to: source.appendingPathComponent(name)) }
        let fileSystem = FaultingFileSystem()
        let store = LibraryStore(root: root, metadata: reader, fileSystem: fileSystem); await store.load()
        #expect(await store.importFiles([source.appendingPathComponent("a.mp3")]).imported == 1)
        let reference = try #require(store.tracks.first?.artwork)

        fileSystem.fail(.write, pathContaining: "catalog")
        var failed = false
        do { try await store.deleteTracks(Set(store.tracks.map(\.id))) } catch { failed = true }
        #expect(failed)
        fileSystem.reset()

        #expect(await store.importFiles([source.appendingPathComponent("b.mp3")]).imported == 1)
        #expect(store.tracks.first?.artwork == reference)

        let reopened = LibraryStore(root: root, metadata: reader); await reopened.load()
        #expect(reopened.tracks.map(\.title) == ["B"])
        #expect(exists(root, reference)); #expect(exists(root, "tracks/" + (reopened.tracks.first?.fileName ?? "")))
        #expect(!exists(root, "tracks/a.mp3")) // the journaled audio of the deleted track is still removed
    }

    /// A journal that already lists live files (written by an older build, or by the scenario
    /// above) is reconciled when the library opens instead of being replayed blindly.
    @Test func journalEntriesForLiveTracksAndPlaylistsAreDroppedAtLoad() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = LibraryDisk(root: root); _ = try await disk.load()
        let track = LibraryTrack(fileName: "live.mp3", title: "Live", artwork: "images/track.image")
        let playlist = LibraryPlaylist(id: UUID(), name: "P", description: "", artwork: "images/playlist.image",
                                       trackIDs: [track.id], dateCreated: .now, dateModified: .now)
        for path in ["tracks/live.mp3", "tracks/orphan.mp3", "images/track.image", "images/playlist.image", "images/orphan.image"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(path))
        }
        try await disk.save(LibraryCatalog(revision: 1, tracks: [track], playlists: [playlist], pendingFileRemovals:
            ["tracks/live.mp3", "tracks/orphan.mp3", "images/track.image", "images/playlist.image", "images/orphan.image"]))
        let store = LibraryStore(root: root); await store.load()
        #expect(store.isLoaded)
        #expect(exists(root, "tracks/live.mp3")); #expect(exists(root, "images/track.image")); #expect(exists(root, "images/playlist.image"))
        #expect(!exists(root, "tracks/orphan.mp3")); #expect(!exists(root, "images/orphan.image"))
        #expect(try persistedCatalog(root).pendingFileRemovals.isEmpty)
    }

    /// Re-using a file that is waiting in the journal takes it off the journal, so a crash before
    /// the next explicit cleanup cannot delete it.
    @Test func reusingJournaledArtworkCancelsItsRemoval() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let cover = Data("cover".utf8)
        let reader = StubMetadataReader(fixtures: ["a.mp3": ImportedAudio(track: LibraryTrack(fileName: "a.mp3", title: "A"), artwork: cover)])
        let source = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: source) }
        try Data("audio".utf8).write(to: source.appendingPathComponent("a.mp3"))
        let fileSystem = FaultingFileSystem()
        let store = LibraryStore(root: root, metadata: reader, fileSystem: fileSystem); await store.load()
        #expect(await store.importFiles([source.appendingPathComponent("a.mp3")]).imported == 1)
        let reference = try #require(store.tracks.first?.artwork)
        let playlistID = try store.createPlaylist(name: "P")
        fileSystem.fail(.write, pathContaining: "catalog")
        do { try await store.deleteTracks(Set(store.tracks.map(\.id))) } catch {}
        fileSystem.reset()
        try await store.setPlaylistArtwork(playlistID, data: cover) // same bytes, same content-addressed file
        #expect(store.playlist(playlistID)?.artwork == reference)
        try await store.flush()
        let catalog = try persistedCatalog(root)
        #expect(!catalog.pendingFileRemovals.contains(reference))
        #expect(catalog.playlists.first?.artwork == reference)
        #expect(exists(root, reference))
    }

    /// Two overlapping artwork replacements: the one requested last wins, and nothing leaks.
    @Test func overlappingPlaylistArtworkReplacementsLastRequestWinsWithoutLeaks() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); await store.load()
        let id = try store.createPlaylist(name: "Mix")
        let first = Task { @MainActor in try await store.setPlaylistArtwork(id, data: Data("first".utf8)) }
        let second = Task { @MainActor in try await store.setPlaylistArtwork(id, data: Data("second".utf8)) }
        try await first.value; try await second.value
        let reference = try #require(store.playlist(id)?.artwork)
        #expect(try Data(contentsOf: root.appendingPathComponent(reference)) == Data("second".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("images").path).count == 1)
        let reopened = LibraryStore(root: root); await reopened.load()
        #expect(reopened.playlist(id)?.artwork == reference)
    }
}
