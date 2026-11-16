import Foundation
import Testing
@testable import Maple

/// Interrupted writes, storage failures and journals replayed after a restart. A "crash" is a
/// store that is simply dropped and a new one opened on the same folders.
@MainActor
struct LibraryCrashRecoveryTests {
    private func exists(_ root: URL, _ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }
    /// Visible entries of a folder (the hidden `.staging` folder is checked separately).
    private func names(_ root: URL, _ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }
    private func audio(_ file: String, title: String, cover: Data? = nil) -> ImportedAudio {
        ImportedAudio(track: LibraryTrack(fileName: file, title: title, artist: "Artist \(title)"), artwork: cover)
    }
    private func write(_ names: [String], in folder: URL) throws {
        for name in names { try Data("audio-\(name)".utf8).write(to: folder.appendingPathComponent(name)) }
    }

    // MARK: Clear Library (§1.4)

    /// An unregistered duplicate in `tracks/` is skipped by the scan, so it used to survive Clear
    /// Library and come back at the next launch.
    @Test func clearLibraryRemovesOrphansLegacyFilesAndStagingSoNothingReturns() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let tracks = root.appendingPathComponent("tracks"), images = root.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: tracks.appendingPathComponent(".staging"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let same = audio("a.mp3", title: "Same")
        let reader = StubMetadataReader(fixtures: ["a.mp3": same, "b.mp3": audio("b.mp3", title: "Same"), "c.mp3": audio("c.mp3", title: "Same")])
        try write(["a.mp3", "b.mp3"], in: tracks)
        // A duplicate dropped elsewhere in Documents is rejected by the scan; Clear must not leave it to be adopted next launch.
        let inbox = root.appendingPathComponent("zInbox"); try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try write(["c.mp3"], in: inbox)
        try Data("legacy".utf8).write(to: tracks.appendingPathComponent("tracks.json"))
        try Data("orphan cover".utf8).write(to: images.appendingPathComponent("unused.image"))
        let store = LibraryStore(root: root, metadata: reader); await store.load()
        let scan = await store.importFiles([root], scan: true)
        #expect(scan.imported == 1); #expect(scan.duplicates == 2)
        try FileManager.default.createDirectory(at: tracks.appendingPathComponent(".staging"), withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: tracks.appendingPathComponent(".staging/x.import")) // an import in flight when Clear was tapped

        try await store.clearLibrary()
        #expect(names(root, "tracks").isEmpty); #expect(names(root, "images").isEmpty)
        #expect(!exists(root, "tracks/.staging")); #expect(!exists(root, "zInbox/c.mp3"))

        let relaunched = LibraryStore(root: root, metadata: reader); await relaunched.load()
        let again = await relaunched.importFiles([root], scan: true)
        #expect(again.imported == 0); #expect(relaunched.tracks.isEmpty)
    }

    /// The emptied catalog and the full list of files to delete are saved together before any
    /// file is removed, so a crash part-way is finished by the journal at the next launch.
    @Test func clearLibraryInterruptedPartWayIsFinishedAtNextLaunch() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tracks"), withIntermediateDirectories: true)
        let reader = StubMetadataReader(fixtures: ["a.mp3": audio("a.mp3", title: "A", cover: Data("cover".utf8))])
        try write(["a.mp3"], in: root.appendingPathComponent("tracks"))
        let fileSystem = FaultingFileSystem()
        let store = LibraryStore(root: root, metadata: reader, fileSystem: fileSystem); await store.load()
        _ = await store.importFiles([root], scan: true)
        _ = try store.createPlaylist(name: "Mix", trackIDs: store.tracks.map(\.id))
        try await store.flush()
        fileSystem.fail(.remove) // the process "dies" as soon as deleting starts
        var failed = false
        do { try await store.clearLibrary() } catch { failed = true }
        #expect(failed)
        #expect(!names(root, "tracks").isEmpty) // nothing was deleted yet…
        let relaunched = LibraryStore(root: root, metadata: reader); await relaunched.load()
        #expect(relaunched.tracks.isEmpty); #expect(relaunched.playlists.isEmpty) // …but the clear was already committed
        #expect(names(root, "tracks").isEmpty); #expect(names(root, "images").isEmpty)
        #expect(await relaunched.importFiles([root], scan: true).imported == 0)
    }

    // MARK: Staging (§1.5)

    @Test func abandonedStagingFilesAreRemovedWhenTheLibraryOpens() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("tracks/.staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("half a copy".utf8).write(to: staging.appendingPathComponent("\(UUID().uuidString).import"))
        let store = LibraryStore(root: root); await store.load()
        #expect(store.isLoaded)
        #expect(!exists(root, "tracks/.staging"))
    }

    @Test func aCopyThatFailsHalfWayLeavesNoFilesAndNoTrackAndTheNextFileStillImports() async throws {
        let root = try makeTemporaryDirectory(), source = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let reader = StubMetadataReader(fixtures: ["a.mp3": audio("a.mp3", title: "A"), "b.mp3": audio("b.mp3", title: "B")])
        try write(["a.mp3", "b.mp3"], in: source)
        let fileSystem = FaultingFileSystem()
        fileSystem.leavePartialCopies(); fileSystem.fail(.copy, times: 1) // disk fills during the first copy only
        let store = LibraryStore(root: root, metadata: reader, fileSystem: fileSystem); await store.load()
        let summary = await store.importFiles([source])
        #expect(summary.imported == 1); #expect(summary.failures.count == 1)
        #expect(store.tracks.map(\.title) == ["B"])
        #expect(names(root, "tracks").count == 1)
        #expect(names(root, "tracks/.staging").isEmpty)
    }

    /// The audio was moved into place but the catalog write never happened (power loss). The
    /// file is not lost: the next scan adopts it.
    @Test func importWhoseCatalogWriteFailedLeavesAudioThatTheNextScanAdopts() async throws {
        let root = try makeTemporaryDirectory(), source = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let reader = StubMetadataReader(fixtures: ["a.mp3": audio("a.mp3", title: "A")], fallback: audio("any", title: "A"))
        try write(["a.mp3"], in: source)
        let fileSystem = FaultingFileSystem()
        let store = LibraryStore(root: root, metadata: reader, fileSystem: fileSystem); await store.load()
        fileSystem.fail(.write, pathContaining: "catalog")
        let summary = await store.importFiles([source])
        #expect(summary.imported == 1); #expect(!summary.failures.isEmpty) // the save failure is reported
        let relaunched = LibraryStore(root: root, metadata: reader); await relaunched.load()
        #expect(relaunched.tracks.isEmpty)
        #expect(names(root, "tracks").count == 1)
        #expect(await relaunched.importFiles([root], scan: true).imported == 1)
        #expect(relaunched.tracks.count == 1)
    }

    // MARK: Atomic catalog writes

    @Test func fullDiskDuringCatalogSaveKeepsThePreviousCatalog() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = FaultingFileSystem()
        let store = LibraryStore(root: root, fileSystem: fileSystem); await store.load()
        let kept = try store.createPlaylist(name: "Kept"); try await store.flush()
        fileSystem.fail(.write, pathContaining: "catalog")
        _ = try store.createPlaylist(name: "Lost")
        var failed = false
        do { try await store.flush() } catch { failed = true }
        #expect(failed)
        let reopened = LibraryStore(root: root); await reopened.load()
        #expect(reopened.playlists.map(\.id) == [kept])
        // Once space is free again the same store saves normally.
        fileSystem.reset(); try await store.flush()
        let again = LibraryStore(root: root); await again.load()
        #expect(again.playlists.map(\.name).sorted() == ["Kept", "Lost"])
    }

    @Test func crashBetweenPrimaryAndBackupWriteLoadsTheNewerPrimary() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = FaultingFileSystem()
        let store = LibraryStore(root: root, fileSystem: fileSystem); await store.load()
        _ = try store.createPlaylist(name: "Old"); try await store.flush()
        fileSystem.fail(.write, pathContaining: "catalog.backup")
        _ = try store.createPlaylist(name: "New")
        do { try await store.flush() } catch {}
        let reopened = LibraryStore(root: root); await reopened.load()
        #expect(reopened.playlists.map(\.name).sorted() == ["New", "Old"]); #expect(reopened.errorMessage == nil)
    }

    @Test func missingPrimaryIsRestoredFromBackup() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); await store.load()
        _ = try store.createPlaylist(name: "Mix"); try await store.flush()
        try FileManager.default.removeItem(at: root.appendingPathComponent("library/catalog.json"))
        let reopened = LibraryStore(root: root); await reopened.load()
        #expect(reopened.playlists.map(\.name) == ["Mix"]); #expect(reopened.errorMessage != nil)
    }

    @Test func missingPrimaryWithCorruptBackupArchivesItAndOpensEmptyInsteadOfStayingClosed() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); await store.load(); try await store.flush()
        try FileManager.default.removeItem(at: root.appendingPathComponent("library/catalog.json"))
        try Data("{ broken".utf8).write(to: root.appendingPathComponent("library/catalog.backup.json"))
        let reopened = LibraryStore(root: root); await reopened.load()
        #expect(reopened.isLoaded); #expect(reopened.errorMessage != nil)
        #expect(names(root, "library").contains { $0.hasPrefix("corrupt-backup-") })
    }

    @Test func unreadablePrimaryIsNotTreatedAsCorrupt() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); await store.load()
        _ = try store.createPlaylist(name: "Mix"); try await store.flush()
        let fileSystem = FaultingFileSystem(); fileSystem.fail(.read, pathContaining: "catalog.json")
        let reopened = LibraryStore(root: root, fileSystem: fileSystem); await reopened.load()
        #expect(!reopened.isLoaded) // a read error must never lead to an empty, writable library
        #expect(names(root, "library").allSatisfy { !$0.hasPrefix("corrupt-") })
        let healthy = LibraryStore(root: root); await healthy.load()
        #expect(healthy.playlists.map(\.name) == ["Mix"])
    }

    // MARK: Partly malformed catalogs

    @Test func oneMalformedTrackRowKeepsTheOthersAndArchivesTheOriginal() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let tracks = root.appendingPathComponent("tracks")
        try FileManager.default.createDirectory(at: tracks, withIntermediateDirectories: true)
        let good = UUID()
        let json = #"{"version":1,"revision":4,"tracks":[{"id":"\#(good.uuidString)","fileName":"a.mp3","title":"A","artist":"B","album":"C","year":0,"genre":"G","duration":1,"trackNumber":1,"discNumber":1,"dateAdded":1},{"id":"not-a-uuid","fileName":"b.mp3"},"junk",{"id":"\#(UUID().uuidString)","fileName":"../escape.mp3","title":"X","artist":"B","album":"C","year":0,"genre":"G","duration":1,"trackNumber":1,"discNumber":1,"dateAdded":1}]}"#
        try FileManager.default.createDirectory(at: root.appendingPathComponent("library"), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: root.appendingPathComponent("library/catalog.json"))
        let store = LibraryStore(root: root); await store.load()
        #expect(store.isLoaded); #expect(store.tracks.map(\.id) == [good]); #expect(store.errorMessage != nil)
        let archive = try #require(names(root, "library").first { $0.hasPrefix("partial-") })
        #expect(try String(contentsOf: root.appendingPathComponent("library/" + archive), encoding: .utf8) == json)
    }

    @Test func loadDropsDanglingAndDuplicatePlaylistAndRecentEntries() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = LibraryDisk(root: root); _ = try await disk.load()
        let track = LibraryTrack(fileName: "a.mp3", title: "A")
        let ghost = UUID()
        let playlist = LibraryPlaylist(id: UUID(), name: "P", description: "", trackIDs: [track.id, ghost, track.id], dateCreated: .now, dateModified: .now)
        try await disk.save(LibraryCatalog(revision: 1, tracks: [track], playlists: [playlist], recentlyPlayed: [ghost, track.id, track.id]))
        let store = LibraryStore(root: root); await store.load()
        #expect(store.playlist(playlist.id)?.trackIDs == [track.id]); #expect(store.recentIDs == [track.id])
    }

    // MARK: Deletion journal replay

    @Test func removalInterruptedAfterJournalingIsFinishedAtNextLaunch() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tracks"), withIntermediateDirectories: true)
        let reader = StubMetadataReader(fixtures: ["a.mp3": audio("a.mp3", title: "A", cover: Data("c".utf8)), "b.mp3": audio("b.mp3", title: "B")])
        try write(["a.mp3", "b.mp3"], in: root.appendingPathComponent("tracks"))
        let fileSystem = FaultingFileSystem()
        let store = LibraryStore(root: root, metadata: reader, fileSystem: fileSystem); await store.load()
        _ = await store.importFiles([root], scan: true)
        #expect(store.tracks.count == 2)
        let doomed = Set(store.tracks.filter { $0.title == "A" }.map(\.id))
        fileSystem.fail(.remove)
        var failed = false
        do { try await store.deleteTracks(doomed) } catch { failed = true }
        #expect(failed); #expect(store.tracks.map(\.title) == ["B"])
        let relaunched = LibraryStore(root: root, metadata: reader); await relaunched.load()
        #expect(relaunched.tracks.map(\.title) == ["B"])
        #expect(names(root, "tracks").count == 1); #expect(names(root, "images").isEmpty)
    }

    @Test func oneFileThatCannotBeRemovedDoesNotBlockTheOthersAndIsRetried() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = LibraryDisk(root: root); _ = try await disk.load()
        for name in ["images/stuck.image", "images/free.image"] { try Data("x".utf8).write(to: root.appendingPathComponent(name)) }
        try await disk.save(LibraryCatalog(revision: 1, pendingFileRemovals: ["images/stuck.image", "images/free.image"]))
        let fileSystem = FaultingFileSystem(); fileSystem.fail(.remove, pathContaining: "stuck")
        let store = LibraryStore(root: root, fileSystem: fileSystem); await store.load()
        #expect(!exists(root, "images/free.image")); #expect(exists(root, "images/stuck.image"))
        #expect(store.errorMessage != nil)
        let healthy = LibraryStore(root: root); await healthy.load()
        #expect(!exists(root, "images/stuck.image"))
    }

    @Test func unsafeJournalEntriesAreDiscardedNotExecuted() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).txt")
        try Data("keep".utf8).write(to: outside); defer { try? FileManager.default.removeItem(at: outside) }
        let disk = LibraryDisk(root: root); _ = try await disk.load()
        try await disk.save(LibraryCatalog(revision: 1, pendingFileRemovals: ["tracks/../../\(outside.lastPathComponent)", "../x", "library/catalog.json"]))
        let store = LibraryStore(root: root); await store.load()
        #expect(store.isLoaded); #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(exists(root, "library/catalog.json"))
    }

    // MARK: Import lifecycle

    /// Cancelling after some files committed keeps those files, drops the rest, and leaves the
    /// catalog consistent with the disk.
    @Test func cancellingMidImportKeepsCommittedTracksAndLeavesNoStragglers() async throws {
        let root = try makeTemporaryDirectory(), source = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let files = ["1.mp3", "2.mp3", "3.mp3"]
        try write(files, in: source)
        let reader = HookedMetadataReader(fixtures: Dictionary(uniqueKeysWithValues: files.map { ($0, audio($0, title: $0)) }))
        let store = LibraryStore(root: root, metadata: reader); await store.load()
        let box = TaskBox()
        reader.afterRead = { count in if count == 2 { box.cancel() } }
        let task = Task { @MainActor in await store.importFiles([source]) }
        box.task = { task.cancel() }
        let summary = await task.value
        #expect(summary.cancelled); #expect(summary.imported == 1)
        #expect(store.tracks.map(\.title) == ["1.mp3"])
        #expect(names(root, "tracks").filter { !$0.hasPrefix(".") }.count == 1); #expect(names(root, "tracks/.staging").isEmpty)
        let reopened = LibraryStore(root: root, metadata: reader); await reopened.load()
        #expect(reopened.tracks.map(\.title) == ["1.mp3"])
    }
}

/// Lets a `@Sendable` hook cancel a task that is created after the hook.
final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?
    var task: (() -> Void)? {
        get { lock.withLock { action } }
        set { lock.withLock { action = newValue } }
    }
    func cancel() { task?() }
}
