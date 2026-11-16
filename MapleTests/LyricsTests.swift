import Foundation
import Testing
@testable import Maple

struct LyricsTests {
    @Test func timestampsMultipleTagsMetadataAndOffsetUseLRCSign() {
        let lyrics = LyricsDocument.parse("\u{feff}[ar:Artist]\n[00:02.50][01:03.125]Same line\n[offset:+500]\n[00:00.20]Early\nUntimed")
        #expect(lyrics.synced)
        #expect(lyrics.lines.map(\.time) == [0, 2, 62.625])
        #expect(lyrics.lines.map(\.text) == ["Early", "Same line", "Same line"])
        #expect(lyrics.currentLine(at: 1) == 0)
        #expect(lyrics.currentLine(at: 2) == 1)
    }
    @Test func negativeOffsetDelaysAndBeforeFirstTimestampHasNoHighlight() {
        let lyrics = LyricsDocument.parse("[offset:-1000]\n[00:02]Line")
        #expect(lyrics.lines.first?.time == 3)
        #expect(lyrics.currentLine(at: 2) == nil)
        #expect(lyrics.currentLine(at: .nan) == nil)
    }
    @Test func plainTextKeepsBlankLinesAndDropsMetadata() {
        let lyrics = LyricsDocument.parse("[ti:Title]\nFirst line\n\nLast line")
        #expect(!lyrics.synced); #expect(lyrics.lines.map(\.text) == ["First line", "", "Last line"])
        #expect(lyrics.currentLine(at: 20) == nil)
    }
    @Test func externalLyricsAreBoundedValidatedAndReadAsText() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = ExternalLyricsReader(), url = directory.appendingPathComponent("lyrics.lrc")
        try Data("[00:01]Hello".utf8).write(to: url)
        #expect(try await reader.read(url) == "[00:01]Hello")
        try Data(repeating: 65, count: 1_048_577).write(to: url)
        await #expect(throws: LyricsError.self) { try await reader.read(url) }
        let invalid = directory.appendingPathComponent("bad.mp3")
        await #expect(throws: LyricsError.self) { try await reader.read(invalid) }
    }
}
