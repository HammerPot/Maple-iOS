import Foundation
import Testing
@testable import Maple

private struct FixtureMetadataReader: LibraryMetadataReading {
    var fixtures: [String: ImportedAudio] = [:]
    func read(_ url: URL) async throws -> ImportedAudio {
        try Task.checkCancellation()
        guard let fixture = fixtures[url.lastPathComponent] else { throw LibraryError.unreadableAudio }
        return fixture
    }
}

@MainActor
struct LibraryStoreTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func seed(_ tracks: [LibraryTrack], root: URL, playlists: [LibraryPlaylist] = []) async throws -> LibraryStore {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tracks"), withIntermediateDirectories: true)
        let disk = LibraryDisk(root: root)
        _ = try await disk.load()
        for track in tracks { try Data("audio".utf8).write(to: root.appendingPathComponent("tracks/" + track.fileName)) }
        try await disk.save(LibraryCatalog(revision: 1, tracks: tracks, playlists: playlists))
        let store = LibraryStore(root: root)
        await store.load(); return store
    }
    @Test func migrationRebasesURLAndKeepsArtworkAndIDs() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tracks"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        let id = UUID()
        let json = """
        [{"id":"\(id.uuidString)","title":"Legacy title","artist":"Legacy artist","album":"Legacy album","year":2020,"genre":"Rock","duration":142.5,"artwork":"/images/cover.image","trackNumber":2,"discNumber":1,"ext":"mp3","url":"file:///var/mobile/Containers/Data/Application/OLD-CONTAINER/Documents/tracks/old.mp3"}]
        """
        try Data(json.utf8).write(to: root.appendingPathComponent("tracks/tracks.json"))
        try Data("audio".utf8).write(to: root.appendingPathComponent("tracks/old.mp3"))
        try Data("image".utf8).write(to: root.appendingPathComponent("images/cover.image"))
        let store = LibraryStore(root: root); await store.load()
        let track = try #require(store.tracks.first)
        #expect(track.id == id); #expect(track.trackNumber == 2); #expect(track.discNumber == 1)
        #expect(store.audioURL(for: track) == root.appendingPathComponent("tracks/old.mp3"))
        #expect(store.artworkURL(track.artwork) == root.appendingPathComponent("images/cover.image"))
        #expect(FileManager.default.fileExists(atPath: store.audioURL(for: track).path))
        try await store.deleteTracks([id])
        let reopened = LibraryStore(root: root); await reopened.load()
        #expect(reopened.tracks.isEmpty) // old JSON never resurrects a deleted track
    }
    @Test func migrationSalvagesSnapshotsAndToleratesMissingAudioAndMalformedRows() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tracks"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("albums"), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: root.appendingPathComponent("tracks/tracks.json"))
        let fixture = #"[{"name":"Album","songs":[{"url":"file:///old/tracks/saved.m4a","title":"Saved","artist":"Artist","album":"Album","artwork":"/images/gone.image"},{"url":"file:///old/tracks/missing.m4a","title":"No audio"},{"title":"Bad row"}]}]"#
        try Data(fixture.utf8).write(to: root.appendingPathComponent("albums/albums.json"))
        try Data("audio".utf8).write(to: root.appendingPathComponent("tracks/saved.m4a"))
        let store = LibraryStore(root: root); await store.load()
        // Corrupt tracks.json is tolerated, the album snapshot salvages the row whose audio exists,
        // and rows without audio (or without a URL) are dropped rather than shown as unplayable.
        #expect(store.tracks.map(\.fileName) == ["saved.m4a"])
        #expect(store.tracks.first?.artwork == nil) // referenced artwork file is gone
        #expect(store.albums.count == 1)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("tracks/saved.m4a").path))
    }
    @Test func migrationRunsOnceAndOrphanAudioIsAdoptedByScan() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tracks"), withIntermediateDirectories: true)
        let json = #"[{"id":"\#(UUID().uuidString)","title":"Listed","artist":"A","album":"X","year":2001,"genre":"","duration":10,"trackNumber":1,"discNumber":1,"ext":"mp3","url":"file:///private/var/OLD/Documents/tracks/listed.mp3"}]"#
        try Data(json.utf8).write(to: root.appendingPathComponent("tracks/tracks.json"))
        for name in ["listed.mp3", "orphan.mp3"] { try Data("audio".utf8).write(to: root.appendingPathComponent("tracks/" + name)) }
        let reader = FixtureMetadataReader(fixtures: ["orphan.mp3": ImportedAudio(track: LibraryTrack(fileName: "orphan.mp3", title: "Orphan"), artwork: nil)])
        let store = LibraryStore(root: root, metadata: reader); await store.load()
        #expect(store.tracks.map(\.title) == ["Listed"])
        #expect(store.tracks.first?.year == 2001)
        let scan = await store.importFiles([root], scan: true)
        #expect(scan.imported == 1)
        #expect(Set(store.tracks.map(\.fileName)) == ["listed.mp3", "orphan.mp3"])
        // Deleting the migrated track must not bring it back from tracks.json on the next launch.
        try await store.deleteTracks(Set(store.tracks.filter { $0.title == "Listed" }.map(\.id)))
        let reopened = LibraryStore(root: root, metadata: reader); await reopened.load()
        #expect(reopened.tracks.map(\.fileName) == ["orphan.mp3"])
    }
    @Test func folderImportRecursesAndReportsPickedNonAudioFiles() async throws {
        let root = try directory(); let source = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let nested = source.appendingPathComponent("Artist/Album", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: nested.appendingPathComponent("deep.flac"))
        try Data("cover".utf8).write(to: nested.appendingPathComponent("cover.jpg")) // ignored inside folders
        try Data(".".utf8).write(to: nested.appendingPathComponent(".hidden.mp3"))   // hidden files skipped
        let notes = source.appendingPathComponent("notes.txt"); try Data("text".utf8).write(to: notes)
        let reader = FixtureMetadataReader(fixtures: ["deep.flac": ImportedAudio(track: LibraryTrack(fileName: "deep.flac", title: "Deep", artist: "Artist"), artwork: Data("art".utf8))])
        let store = LibraryStore(root: root, metadata: reader); await store.load()
        let summary = await store.importFiles([source, notes])
        #expect(summary.imported == 1)
        #expect(summary.failures.count == 1); #expect(summary.failures.first?.hasPrefix("notes.txt") == true)
        let track = try #require(store.tracks.first)
        #expect(track.fileName == "\(track.id.uuidString).flac")
        #expect(FileManager.default.fileExists(atPath: store.audioURL(for: track).path))
        #expect(FileManager.default.fileExists(atPath: nested.appendingPathComponent("deep.flac").path)) // copied, not moved
        #expect(try store.artworkURL(track.artwork).map { try Data(contentsOf: $0) } == Data("art".utf8))
    }
    @Test func duplicateIsDetectedBeforeAudioCopy() async throws {
        let root = try directory(); let source = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let existing = LibraryTrack(fileName: "existing.mp3", title: "Café", artist: "Artist")
        let fixture = ImportedAudio(track: LibraryTrack(fileName: "duplicate.mp3", title: " CAFE ", artist: "artist"), artwork: nil)
        let store = try await seed([existing], root: root)
        try await store.flush()
        let importing = LibraryStore(root: root, metadata: FixtureMetadataReader(fixtures: ["duplicate.mp3": fixture])); await importing.load()
        let url = source.appendingPathComponent("duplicate.mp3"); try Data("audio".utf8).write(to: url)
        let result = await importing.importFiles([url])
        #expect(result.duplicates == 1); #expect(result.imported == 0); #expect(result.failures.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("tracks").path)
        #expect(files == ["existing.mp3"])
    }
    @Test func duplicateWithinSameBatchAndFailedImportSummary() async throws {
        let root = try directory(); let source = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let track = LibraryTrack(fileName: "a.mp3", title: "Same", artist: "Same")
        let fixture = ImportedAudio(track: track, artwork: nil)
        let store = LibraryStore(root: root, metadata: FixtureMetadataReader(fixtures: ["a.mp3": fixture, "b.mp3": fixture])); await store.load()
        for name in ["a.mp3", "b.mp3", "bad.mp3"] { try Data("audio".utf8).write(to: source.appendingPathComponent(name)) }
        let result = await store.importFiles([source])
        #expect(result.imported == 1); #expect(result.duplicates == 1); #expect(result.failures.count == 1)
        #expect(store.tracks.count == 1)
    }
    @Test func albumArtistSeparatesNamesAndUntaggedCompilationsStayTogether() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let tracks = [
            LibraryTrack(fileName: "a.mp3", title: "B", artist: "One", album: "Shared", albumArtist: "One", trackNumber: 2, discNumber: 1),
            LibraryTrack(fileName: "b.mp3", title: "A", artist: "One", album: "Shared", albumArtist: "One", trackNumber: 1, discNumber: 1),
            LibraryTrack(fileName: "c.mp3", title: "C", artist: "Two", album: "Shared", albumArtist: "Two"),
            LibraryTrack(fileName: "d.mp3", title: "D", artist: "Three", album: "Compilation"),
            LibraryTrack(fileName: "e.mp3", title: "E", artist: "Four", album: "Compilation")]
        let store = try await seed(tracks, root: root)
        #expect(store.albums.count == 3); #expect(store.artists.count == 4)
        let first = try #require(store.albums.first { $0.artist == "One" })
        #expect(first.trackIDs == [tracks[1].id, tracks[0].id])
        #expect(store.albums.first { $0.name == "Compilation" }?.artist == "Various Artists")
    }
    @Test func playlistsDeduplicateReorderAndDuplicateIndependently() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let a = LibraryTrack(fileName: "a.mp3", title: "A"), b = LibraryTrack(fileName: "b.mp3", title: "B")
        let store = try await seed([a, b], root: root)
        let id = try store.createPlaylist(name: "Mix", description: "Description", trackIDs: [a.id, a.id, UUID()])
        store.addTracks([a.id, b.id, b.id], to: id)
        #expect(store.playlist(id)?.trackIDs == [a.id, b.id])
        store.setPlaylistTracks(id, ids: [b.id, a.id, b.id])
        #expect(store.playlist(id)?.trackIDs == [b.id, a.id])
        let copy = try #require(try store.duplicatePlaylist(id))
        #expect(store.playlist(copy)?.name == "Mix (Copy)")
        try store.updatePlaylist(copy, name: "Renamed", description: "New")
        store.setPlaylistTracks(copy, ids: [])
        #expect(store.playlist(id)?.name == "Mix"); #expect(store.playlist(id)?.description == "Description")
        #expect(store.playlist(id)?.trackIDs.count == 2); #expect(store.playlist(copy)?.trackIDs.isEmpty == true)
        #expect(throws: LibraryError.self) { try store.createPlaylist(name: "   ") }
    }
    @Test func trackDeletionCascadesToFilesGroupsPlaylistsStatsAndRecent() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let a = LibraryTrack(fileName: "a.mp3", title: "A", artwork: "images/shared.image")
        let b = LibraryTrack(fileName: "b.mp3", title: "B", artwork: "images/shared.image")
        let store = try await seed([a,b], root: root)
        try Data("art".utf8).write(to: root.appendingPathComponent("images/shared.image"))
        let id = try store.createPlaylist(name: "Mix", trackIDs: [a.id,b.id])
        store.recordStart(a.id); store.recordEnd(a.id, completed: true)
        var removed: Set<UUID> = []
        store.willDeleteTracks = { removed = $0 }
        try await store.deleteTracks([a.id])
        #expect(removed == [a.id]); #expect(store.track(a.id) == nil); #expect(store.statistics[a.id] == nil); #expect(store.recentIDs.isEmpty)
        #expect(store.playlist(id)?.trackIDs == [b.id]); #expect(!FileManager.default.fileExists(atPath: store.audioURL(for: a).path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("images/shared.image").path))
        try await store.deleteTracks([b.id])
        #expect(store.albums.isEmpty); #expect(store.artists.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("images/shared.image").path))
    }
    @Test func deletingPlaylistOnlyRemovesOrphanedCustomArtwork() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try await seed([LibraryTrack(fileName: "a.mp3", title: "A")], root: root)
        let id = try store.createPlaylist(name: "Mix")
        try await store.setPlaylistArtwork(id, data: Data("custom image".utf8))
        let reference = try #require(store.playlist(id)?.artwork)
        let duplicate = try #require(try store.duplicatePlaylist(id))
        try await store.deletePlaylist(id)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(reference).path))
        try await store.deletePlaylist(duplicate)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(reference).path))
        #expect(store.tracks.count == 1)
    }
    @Test func replayMovesRecentToFrontAndCompletionIsNotSkip() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let a = LibraryTrack(fileName: "a.mp3", title: "A"), b = LibraryTrack(fileName: "b.mp3", title: "B")
        let store = try await seed([a,b], root: root)
        store.recordStart(a.id); store.recordStart(b.id); store.recordStart(a.id)
        store.recordEnd(a.id, completed: true); store.recordEnd(b.id, completed: false)
        store.recordListening(a.id, seconds: 1.5); store.recordListening(a.id, seconds: -.infinity); store.recordListening(a.id, seconds: 100)
        try await store.flush() // listening time is buffered and folded in on flush/end
        #expect(store.recentIDs == [a.id,b.id]); #expect(store.statistics[a.id]?.plays == 2)
        #expect(store.statistics[a.id]?.completions == 1); #expect(store.statistics[a.id]?.skips == 0)
        #expect(store.statistics[a.id]?.listeningSeconds == 1.5); #expect(store.statistics[b.id]?.skips == 1)
        store.clearRecentlyPlayed(); #expect(store.recentIDs.isEmpty); #expect(store.statistics[a.id]?.plays == 2)
    }
    @Test func clearLibraryClearsMediaPlaylistsStatsAndRecent() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let a = LibraryTrack(fileName: "a.mp3", title: "A", artwork: "images/a.image")
        let store = try await seed([a], root: root)
        try Data("art".utf8).write(to: root.appendingPathComponent("images/a.image"))
        _ = try store.createPlaylist(name: "Mix", trackIDs: [a.id]); store.recordStart(a.id)
        try await store.clearLibrary()
        #expect(store.tracks.isEmpty); #expect(store.playlists.isEmpty); #expect(store.statistics.isEmpty); #expect(store.recentIDs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("tracks/a.mp3").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("images/a.image").path))
        let reopened = LibraryStore(root: root); await reopened.load(); #expect(reopened.tracks.isEmpty)
    }
    @Test func persistenceRoundTripAndCorruptCatalogRecovery() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let a = LibraryTrack(fileName: "a.flac", title: "A", albumArtist: "Album Artist", lyrics: "[00:01.00]Hello")
        let store = try await seed([a], root: root)
        let id = try store.createPlaylist(name: "Mix", trackIDs: [a.id]); store.recordStart(a.id); try await store.flush()
        try Data("broken JSON".utf8).write(to: root.appendingPathComponent("library/catalog.json"))
        let recovered = LibraryStore(root: root); await recovered.load()
        #expect(recovered.tracks == [a]); #expect(recovered.playlist(id)?.trackIDs == [a.id])
        #expect(recovered.statistics[a.id]?.plays == 1); #expect(recovered.recentIDs == [a.id]); #expect(recovered.errorMessage != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("library").path).contains { $0.hasPrefix("corrupt-") })
    }
    @Test func corruptBothCopiesDoesNotRerunLegacyMigration() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try await seed([], root: root); try await store.flush()
        for name in ["catalog.json", "catalog.backup.json"] { try Data("invalid".utf8).write(to: root.appendingPathComponent("library/" + name)) }
        try Data(#"[{"url":"file:///old/tracks/deleted.mp3","title":"Deleted"}]"#.utf8).write(to: root.appendingPathComponent("tracks/tracks.json"))
        let recovered = LibraryStore(root: root); await recovered.load()
        #expect(recovered.isLoaded); #expect(recovered.tracks.isEmpty); #expect(recovered.errorMessage != nil)
    }
    @Test func cancelledImportKeepsPriorTracksAndDoesNotCopy() async throws {
        let root = try directory(); let source = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let url = source.appendingPathComponent("a.mp3"); try Data("audio".utf8).write(to: url)
        let store = LibraryStore(root: root); await store.load()
        let task = Task { @MainActor in await store.importFiles([url]) }; task.cancel()
        let summary = await task.value
        #expect(summary.cancelled); #expect(store.tracks.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("tracks").path).isEmpty)
    }
    @Test func scanImportsInPlaceAndIgnoresKnownFiles() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = ImportedAudio(track: LibraryTrack(fileName: "dropped.wav", title: "Dropped"), artwork: nil)
        let store = LibraryStore(root: root, metadata: FixtureMetadataReader(fixtures: ["dropped.wav": fixture])); await store.load()
        try Data("audio".utf8).write(to: root.appendingPathComponent("tracks/dropped.wav"))
        let first = await store.importFiles([root], scan: true)
        let second = await store.importFiles([root], scan: true)
        #expect(first.imported == 1); #expect(second.imported == 0); #expect(second.duplicates == 0)
        #expect(store.tracks.first?.fileName == "dropped.wav")
    }
    @Test func identicalCoversShareOneFileUntilTheLastTrackGoes() async throws {
        let root = try directory(); let source = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let cover = Data("same album cover".utf8)
        let reader = FixtureMetadataReader(fixtures: [
            "1.mp3": ImportedAudio(track: LibraryTrack(fileName: "1.mp3", title: "One", album: "A"), artwork: cover),
            "2.mp3": ImportedAudio(track: LibraryTrack(fileName: "2.mp3", title: "Two", album: "A"), artwork: cover)])
        for name in ["1.mp3", "2.mp3"] { try Data("audio".utf8).write(to: source.appendingPathComponent(name)) }
        let store = LibraryStore(root: root, metadata: reader); await store.load()
        #expect(await store.importFiles([source]).imported == 2)
        let references = Set(store.tracks.compactMap(\.artwork))
        #expect(references.count == 1)
        let reference = try #require(references.first)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("images").path).count == 1)
        try await store.deleteTracks([store.tracks[0].id])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(reference).path))
        try await store.deleteTracks([store.tracks[0].id])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(reference).path))
    }
}
