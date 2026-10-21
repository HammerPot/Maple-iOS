import Foundation
import Testing
@testable import Maple

struct MapleLibraryTests {
    @Test func migrationPreservesMusicAndLeavesUnrelatedDocumentsAlone() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appending(path: "old")
        let new = root.appending(path: "new")
        try FileManager.default.createDirectory(at: old.appending(path: "tracks"), withIntermediateDirectories: true)
        let track = Data("original track".utf8)
        try track.write(to: old.appending(path: "tracks/song.m4a"))
        try Data("personal document".utf8).write(to: old.appending(path: "notes.txt"))
        try FileManager.default.createDirectory(at: old.appending(path: "images/nested"), withIntermediateDirectories: true)
        try track.write(to: old.appending(path: "images/nested/artwork.image"))
        try MapleLibrary.migrate(from: old, to: new)
        #expect(try Data(contentsOf: new.appending(path: "images/nested/artwork.image")) == track)
        #expect(try Data(contentsOf: new.appending(path: "tracks/song.m4a")) == track)
        #expect(try Data(contentsOf: old.appending(path: "tracks/song.m4a")) == track)
        #expect(!FileManager.default.fileExists(atPath: new.appending(path: "notes.txt").path))
        #expect(FileManager.default.fileExists(atPath: old.appending(path: "notes.txt").path))
    }

    @Test func migrationResumesWithoutOverwritingNewerLibraryFiles() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appending(path: "old")
        let new = root.appending(path: "new")
        for directory in [old, new] {
            try FileManager.default.createDirectory(at: directory.appending(path: "tracks"), withIntermediateDirectories: true)
        }
        try Data("old".utf8).write(to: old.appending(path: "tracks/tracks.json"))
        try Data("new".utf8).write(to: new.appending(path: "tracks/tracks.json"))
        try Data("missing track".utf8).write(to: old.appending(path: "tracks/second.m4a"))
        try MapleLibrary.migrate(from: old, to: new)
        #expect(try String(contentsOf: new.appending(path: "tracks/tracks.json"), encoding: .utf8) == "new")
        #expect(FileManager.default.fileExists(atPath: new.appending(path: "tracks/second.m4a").path))
        // A later launch must not restore tracks the user subsequently removed.
        try FileManager.default.removeItem(at: new.appending(path: "tracks/second.m4a"))
        try MapleLibrary.migrate(from: old, to: new)
        #expect(!FileManager.default.fileExists(atPath: new.appending(path: "tracks/second.m4a").path))
    }
}
