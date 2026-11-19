import Foundation

struct LyricLine: Identifiable, Equatable, Sendable {
    var id: Int
    var time: Double?
    var text: String
}
struct LyricsDocument: Equatable, Sendable {
    var lines: [LyricLine]
    var synced: Bool { lines.contains { $0.time != nil } }
    func currentLine(at seconds: Double) -> Int? {
        guard seconds.isFinite else { return nil }
        // Upper bound: equal timestamps highlight the last matching line consistently.
        var low = 0, high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if let time = lines[middle].time, time <= seconds { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? lines[low - 1].id : nil
    }
    static func parseForPresentation(_ text: String,
        parse: @Sendable (String) async -> Self = { text in await Task.detached { Self.parse(text) }.value }
    ) async -> Self? {
        let result = await parse(text)
        guard !Task.isCancelled else { return nil }
        return result
    }
    static func parse(_ text: String) -> Self {
        let rows = text.replacingOccurrences(of: "\u{feff}", with: "").components(separatedBy: .newlines)
        let timestamps = /\[(\d+):(\d{2}(?:\.\d+)?)\]/
        let offsetTag = /(?i)\[offset:([+-]?\d+)\]/
        let metadata = /\[[A-Za-z]+:[^\]]*\]/
        let offset = rows.compactMap { $0.firstMatch(of: offsetTag).flatMap { Double($0.1) } }.last ?? 0
        var timed: [(Double, String, Int)] = []
        var plain: [String] = []
        for (rowIndex, row) in rows.enumerated() {
            let matches = row.matches(of: timestamps)
            let clean = row.replacing(timestamps, with: "").replacing(metadata, with: "").trimmingCharacters(in: .whitespaces)
            if !matches.isEmpty {
                for match in matches {
                    guard let minutes = Double(match.1), let seconds = Double(match.2), seconds < 60 else { continue }
                    // LRC convention: positive offset makes lyrics appear earlier (subtract milliseconds).
                    let time = max(0, minutes * 60 + seconds - offset / 1000)
                    if time.isFinite { timed.append((time, clean, rowIndex)) }
                }
            } else if !clean.isEmpty || row.trimmingCharacters(in: .whitespaces).isEmpty { plain.append(clean) }
        }
        if !timed.isEmpty {
            timed.sort { $0.0 == $1.0 ? $0.2 < $1.2 : $0.0 < $1.0 }
            return Self(lines: timed.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) })
        }
        return Self(lines: plain.enumerated().map { LyricLine(id: $0.offset, text: $0.element) })
    }
}

actor ExternalLyricsReader {
    func read(_ url: URL) throws -> String {
        guard ["lrc", "txt"].contains(url.pathExtension.lowercased()) else { throw LyricsError.invalidFile }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw LyricsError.invalidFile }
        guard let text = String(data: data, encoding: .utf8), LyricsDocument.parse(text).lines.contains(where: { !$0.text.isEmpty }) else { throw LyricsError.empty }
        return text
    }
}

enum LyricsError: LocalizedError {
    case invalidFile, empty
    var errorDescription: String? {
        switch self {
        case .invalidFile: "Choose an LRC or TXT file no larger than 1 MB."
        case .empty: "The lyrics file is empty or is not UTF-8 text."
        }
    }
}
