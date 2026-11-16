import Foundation
import AVFoundation
import UniformTypeIdentifiers
import MapleTagReader

struct ImportedAudio: Sendable {
    var track: LibraryTrack
    var artwork: Data?
    /// False when the title or artist is a stand-in (file name, "Unknown Artist") rather than
    /// something the file's tags said, so title-and-artist cannot identify a duplicate.
    var hasTitleAndArtist = true
}

enum LibraryLimits {
    /// Larger embedded pictures are ignored instead of copied, hashed and stored.
    static let maximumArtworkBytes = 20 * 1024 * 1024
}

protocol LibraryMetadataReading: Sendable {
    func read(_ url: URL) async throws -> ImportedAudio
}

/// Reads tags with TagLib and admits a file only if the system decoder can play it.
///
/// TagLib (the Swift-side counterpart of upstream's `music-metadata`) is the primary source:
/// it reads ID3v2.3/2.4, MP4 atoms, Vorbis comments/FLAC pictures and ID3-in-AIFF/WAV
/// uniformly, including album artist, disc numbers and SYLT synchronised lyrics, none of
/// which AVFoundation exposes consistently. AVFoundation is used for the playability check,
/// the duration the player will see, and as a fallback for files TagLib cannot parse.
actor AudioMetadataReader: LibraryMetadataReading {
    /// Extensions worth trying. Being listed does not admit a file: decoding does.
    static let candidateExtensions: Set<String> = [
        "mp3", "mp2", "m4a", "m4b", "m4p", "mp4", "aac", "adts", "wav", "wave", "aif", "aiff", "aifc", "caf",
        "flac", "alac", "ac3", "eac3", "ec3", "au", "snd", "sd2", "3gp", "3gpp", "3g2", "amr", "ogg", "oga", "opus",
    ]
    nonisolated static func isCandidate(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return candidateExtensions.contains(ext) || UTType(filenameExtension: ext)?.conforms(to: .audio) == true
    }

    /// Missing values and common "nobody filled this in" strings.
    nonisolated static func isPlaceholder(_ value: String?) -> Bool {
        guard let value else { return true }
        return ["", "unknown", "unknown artist", "unknown title", "<unknown>", "[unknown]", "untitled"]
            .contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    func read(_ url: URL) async throws -> ImportedAudio {
        try Task.checkCancellation()
        // The local player uses AVAudioPlayer, so the same decoder is the admission check.
        // This rejects unsupported codecs, video-only MP4s and damaged files before any copy.
        let duration: TimeInterval
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            duration = player.duration
        } catch { throw LibraryError.unreadableAudio }
        guard duration.isFinite, duration > 0 else { throw LibraryError.unreadableAudio }

        let tags = MapleTagReader.metadata(at: url)
        var values: [String: String] = [:]
        for (field, tag) in [("title", "TITLE"), ("artist", "ARTIST"), ("album", "ALBUM"),
                             ("albumArtist", "ALBUMARTIST"), ("year", "DATE"), ("genre", "GENRE"),
                             ("track", "TRACKNUMBER"), ("disc", "DISCNUMBER"), ("lyrics", "LYRICS")] {
            if let text = tags[tag] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { values[field] = text }
        }
        if values["lyrics"] == nil {
            // USLT frames with a description surface as "LYRICS:<description>"; some taggers
            // (including ffmpeg) write lyrics as a TXXX user-text frame named USLT or UNSYNCEDLYRICS.
            values["lyrics"] = tags.keys.sorted()
                .first { $0.hasPrefix("LYRICS:") || $0 == "UNSYNCEDLYRICS" || $0 == "USLT" }
                .flatMap { tags[$0] as? String }
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        var artwork = tags["artwork"] as? Data
        if values["title"] == nil || values["artist"] == nil || artwork == nil {
            try await fillFromAVFoundation(url, values: &values, artwork: &artwork)
        }
        func number(_ key: String) -> Int {
            Int((values[key] ?? "").split(separator: "/").first?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        }
        let track = LibraryTrack(
            fileName: url.lastPathComponent, title: values["title"] ?? "", artist: values["artist"] ?? "",
            album: values["album"] ?? "", albumArtist: values["albumArtist"], year: Int((values["year"] ?? "").prefix(4)) ?? 0,
            genre: values["genre"] ?? "", duration: duration, trackNumber: number("track"), discNumber: number("disc"),
            lyrics: values["lyrics"])
        // Oversized pictures are dropped rather than hashed and stored (see `LibraryLimits`).
        let bounded = artwork.flatMap { $0.isEmpty || $0.count > LibraryLimits.maximumArtworkBytes ? nil : $0 }
        return ImportedAudio(track: track, artwork: bounded,
                             hasTitleAndArtist: !Self.isPlaceholder(values["title"]) && !Self.isPlaceholder(values["artist"]))
    }

    /// Fallback for formats or tags TagLib does not cover; never overrides TagLib values.
    private func fillFromAVFoundation(_ url: URL, values: inout [String: String], artwork: inout Data?) async throws {
        let asset = AVURLAsset(url: url)
        let items = (try? await asset.load(.metadata)) ?? []
        for item in items {
            try Task.checkCancellation()
            if item.commonKey == .commonKeyArtwork {
                if artwork == nil { artwork = try? await item.load(.dataValue) }
                continue
            }
            let field: String? = switch item.commonKey {
            case .commonKeyTitle: "title"
            case .commonKeyArtist: "artist"
            case .commonKeyAlbumName: "album"
            case .commonKeyCreationDate: "year"
            default: nil
            }
            guard let field, values[field] == nil, let text = try? await item.load(.stringValue),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            values[field] = text
        }
        if values["lyrics"] == nil, let lyrics = try? await asset.load(.lyrics), !lyrics.isEmpty { values["lyrics"] = lyrics }
    }
}
