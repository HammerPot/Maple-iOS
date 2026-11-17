import Foundation
import Testing
@testable import Maple

/// Catalog compatibility: older shapes load, newer shapes are never touched, and damage is
/// archived rather than overwritten.
@MainActor
struct LibrarySchemaTests {
    private let newer = Data(#"{"version":2,"revision":9,"tracks":[{"future":"shape"}],"playlists":[],"somethingNew":{"a":1}}"#.utf8)
    private let garbage = Data("{ not json".utf8)

    private func library(_ root: URL, primary: Data?, backup: Data?) throws {
        let folder = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tracks"), withIntermediateDirectories: true)
        if let primary { try primary.write(to: folder.appendingPathComponent("catalog.json")) }
        if let backup { try backup.write(to: folder.appendingPathComponent("catalog.backup.json")) }
    }
    private func bytes(_ root: URL, _ name: String) -> Data? { try? Data(contentsOf: root.appendingPathComponent("library/" + name)) }
    private func archives(_ root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("library").path)) ?? []).filter { $0.hasPrefix("corrupt-") }
    }

    /// Everything the app does after a failed load: the automatic scan, flush, clear.
    private func exercise(_ store: LibraryStore, root: URL) async {
        store.scanForNewFiles(silently: true)
        let scan = await store.importFiles([root], scan: true)
        #expect(scan.imported == 0)
        await #expect(throws: LibraryError.self) { try await store.flush() }
        await #expect(throws: LibraryError.self) { try await store.clearLibrary() }
    }

    /// §1.3: a damaged primary and an intact newer-version backup. Nothing may be rewritten.
    @Test func corruptPrimaryWithNewerBackupIsNeverOverwritten() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try library(root, primary: garbage, backup: newer)
        let store = LibraryStore(root: root); await store.load()
        #expect(!store.isLoaded); #expect(store.loadError?.contains("newer") == true)
        await exercise(store, root: root)
        #expect(bytes(root, "catalog.backup.json") == newer); #expect(bytes(root, "catalog.json") == garbage)
        #expect(archives(root).isEmpty) // a library that stays closed must not pile up archives on every launch
    }

    @Test func newerPrimaryIsNeverReplacedByAnOlderBackup() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try JSONEncoder().encode(LibraryCatalog(revision: 3))
        try library(root, primary: newer, backup: old)
        let store = LibraryStore(root: root); await store.load()
        #expect(!store.isLoaded)
        await exercise(store, root: root)
        #expect(bytes(root, "catalog.json") == newer); #expect(bytes(root, "catalog.backup.json") == old)
    }

    @Test func newerBackupWithMissingPrimaryIsLeftAlone() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try library(root, primary: nil, backup: newer)
        let store = LibraryStore(root: root); await store.load()
        #expect(!store.isLoaded)
        await exercise(store, root: root)
        #expect(bytes(root, "catalog.backup.json") == newer); #expect(bytes(root, "catalog.json") == nil)
    }

    @Test func bothCopiesNewerAreLeftAlone() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try library(root, primary: newer, backup: newer)
        let store = LibraryStore(root: root); await store.load()
        #expect(!store.isLoaded)
        await exercise(store, root: root)
        #expect(bytes(root, "catalog.json") == newer); #expect(bytes(root, "catalog.backup.json") == newer)
    }

    /// A catalog from the first rebuild commit lacks every optional key.
    @Test func minimalOlderCatalogLoads() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let json = #"{"version":1,"tracks":[{"id":"\#(id.uuidString)","fileName":"a.mp3","title":"A","artist":"B","album":"C","year":0,"genre":"G","duration":1,"trackNumber":1,"discNumber":1,"dateAdded":700000000}]}"#
        try library(root, primary: Data(json.utf8), backup: nil)
        try Data("x".utf8).write(to: root.appendingPathComponent("tracks/a.mp3"))
        let store = LibraryStore(root: root); await store.load()
        #expect(store.isLoaded); #expect(store.tracks.map(\.id) == [id])
        #expect(store.playlists.isEmpty); #expect(store.statistics.isEmpty); #expect(store.errorMessage == nil)
    }

    /// L1: a row that is not even an object used to make the whole catalog "corrupt" (and the backup, which holds the
    /// same bytes, too). Damaged rows of every JSON shape are skipped like any other damaged row.
    @Test func rowsOfAnyShapeAreSalvagedInsteadOfDiscardingTheCatalog() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let good = #"{"id":"\#(id.uuidString)","fileName":"a.mp3","title":"A","artist":"B","album":"C","year":0,"genre":"G","duration":1,"trackNumber":1,"discNumber":1,"dateAdded":700000000}"#
        let json = #"{"version":1,"tracks":[null,7,"text",true,[1,2],{"fileName":5},\#(good)],"playlists":[null,"x"],"recentlyPlayed":[]}"#
        try library(root, primary: Data(json.utf8), backup: Data(json.utf8))
        try Data("x".utf8).write(to: root.appendingPathComponent("tracks/a.mp3"))
        let store = LibraryStore(root: root); await store.load()
        #expect(store.isLoaded); #expect(store.loadError == nil)
        #expect(store.tracks.map(\.id) == [id]); #expect(store.playlists.isEmpty)
        #expect(store.errorMessage != nil, "The skipped rows are reported")
        #expect(archives(root).isEmpty, "Nothing is archived as corrupt")
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("library").path))?.filter { $0.hasPrefix("partial-") } ?? []
        #expect(kept.count == 1, "The original is kept before the cleaned catalog replaces it")
    }

    /// L3: the background save of a library that never loaded has nothing to write and must not raise an error.
    @Test func backgroundFlushOfAnUnloadedLibraryIsSilent() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try library(root, primary: newer, backup: nil)
        let store = LibraryStore(root: root); await store.load()
        #expect(!store.isLoaded)
        try await store.flushIfLoaded()
        await #expect(throws: LibraryError.self) { try await store.flush() }
        #expect(bytes(root, "catalog.json") == newer, "Nothing was written")
    }

    @Test func backgroundFlushOfALoadedLibrarySavesIt() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try library(root, primary: Data(#"{"version":1,"tracks":[]}"#.utf8), backup: nil)
        let store = LibraryStore(root: root); await store.load()
        #expect(store.isLoaded)
        try await store.flushIfLoaded()
        #expect(bytes(root, "catalog.json") != nil)
    }

    /// Unknown keys in a version-1 catalog (written by a later 1.x build) are tolerated.
    @Test func unknownKeysInAVersionOneCatalogAreIgnored() async throws {
        let root = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try library(root, primary: Data(#"{"version":1,"tracks":[],"futureField":[1,2,3]}"#.utf8), backup: nil)
        let store = LibraryStore(root: root); await store.load()
        #expect(store.isLoaded); #expect(store.errorMessage == nil)
    }
}
