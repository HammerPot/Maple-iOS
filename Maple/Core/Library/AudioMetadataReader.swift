import Foundation
import AVFoundation
import AudioToolbox
import UniformTypeIdentifiers
import MapleTagReader

struct ImportedAudio: Sendable {
    var track: LibraryTrack
    var artwork: Data?
}

protocol LibraryMetadataReading: Sendable {
    func read(_ url: URL) async throws -> ImportedAudio
}

/// Native decoding is the admission check: an extension alone never proves playability.
actor AudioMetadataReader: LibraryMetadataReading {
    static let candidateExtensions: Set<String> = ["mp3", "mp2", "m4a", "m4b", "mp4", "aac", "adts", "wav", "wave", "aif", "aiff", "aifc", "caf", "flac", "alac", "ac3", "eac3", "au", "snd", "sd2", "3gp", "3gpp", "3g2", "amr", "ogg", "oga", "opus", "webm", "wma"]
    nonisolated static func isCandidate(_ url: URL) -> Bool { candidateExtensions.contains(url.pathExtension.lowercased()) || UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true }

    func read(_ url: URL) async throws -> ImportedAudio {
        try Task.checkCancellation()
        // This is also the decoder used by the current local player. Reject unsupported codecs,
        // video-only MP4s and invalid files before copying anything into the library.
        let player = try AVAudioPlayer(contentsOf: url)
        guard player.duration.isFinite, player.duration > 0 else { throw LibraryError.unreadableAudio }
        let asset = AVURLAsset(url: url)
        var values: [String: String] = [:]
        var art: Data?
        let metadata = (try? await asset.load(.metadata)) ?? []
        for item in metadata {
            try Task.checkCancellation()
            let identifier = item.identifier?.rawValue.lowercased() ?? ""
            if item.commonKey == .commonKeyArtwork || identifier.hasSuffix("/apic") || identifier.hasSuffix("/covr") {
                if art == nil { art = try? await item.load(.dataValue) }
                continue
            }
            guard let text = try? await item.load(.stringValue), !text.isEmpty else { continue }
            if item.commonKey == .commonKeyTitle { values["title"] = text }
            if item.commonKey == .commonKeyArtist { values["artist"] = text }
            if item.commonKey == .commonKeyAlbumName { values["album"] = text }
            let suffix = identifier.split(separator: "/").last.map(String.init) ?? identifier
            switch suffix {
            case "tit2", "©nam", "title": values["title"] = text
            case "tpe1", "©art", "artist": values["artist"] = text
            case "talb", "©alb", "album": values["album"] = text
            case "tpe2", "aart", "albumartist", "album_artist": values["albumArtist"] = text
            case "tyer", "tdrc", "©day", "date", "year": values["year"] = text
            case "tcon", "©gen", "gnre", "genre": values["genre"] = text
            case "trck", "trkn", "tracknumber", "track": values["track"] = text
            case "tpos", "disk", "discnumber", "disc": values["disc"] = text
            case "uslt", "sylt", "©lyr", "lyrics", "unsyncedlyrics": values["lyrics"] = text
            default: break
            }
        }
        // Core Audio exposes container-specific tags such as MP4's numeric track number
        // as dictionary values, avoiding hand-decoding ID3 frames or MP4 atoms.
        var audioFile: AudioFileID?
        if AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile) == noErr, let audioFile {
            defer { AudioFileClose(audioFile) }
            var info: CFDictionary?
            var size = UInt32(MemoryLayout<CFDictionary?>.size)
            if AudioFileGetProperty(audioFile, kAudioFilePropertyInfoDictionary, &size, &info) == noErr,
               let dictionary = info as? [String: Any] {
                for (field, key) in [("title", kAFInfoDictionary_Title), ("artist", kAFInfoDictionary_Artist),
                                      ("album", kAFInfoDictionary_Album), ("year", kAFInfoDictionary_Year),
                                      ("genre", kAFInfoDictionary_Genre), ("track", kAFInfoDictionary_TrackNumber)] {
                    if values[field] == nil, let value = dictionary[key] { values[field] = String(describing: value) }
                }
            }
        }
        if values["lyrics"] == nil { values["lyrics"] = try? await asset.load(.lyrics) }
        let tags = MapleTagReader.metadata(at: url)
        for (field, tag) in [("title", "TITLE"), ("artist", "ARTIST"), ("album", "ALBUM"),
                             ("albumArtist", "ALBUMARTIST"), ("year", "DATE"), ("genre", "GENRE"),
                             ("track", "TRACKNUMBER"), ("disc", "DISCNUMBER"), ("lyrics", "LYRICS")] {
            if let text = tags[tag] as? String, !text.isEmpty { values[field] = text }
        }
        // Some encoders store USLT or LYRICS as a user-text frame.
        if values["lyrics"] == nil { values["lyrics"] = tags["USLT"] as? String }
        if let picture = tags["artwork"] as? Data { art = picture }
        func number(_ key: String) -> Int { Int((values[key] ?? "").split(separator: "/").first ?? "") ?? 0 }
        let year = Int((values["year"] ?? "").prefix(4)) ?? 0
        return ImportedAudio(track: LibraryTrack(fileName: url.lastPathComponent, title: values["title"] ?? url.deletingPathExtension().lastPathComponent,
            artist: values["artist"] ?? "", album: values["album"] ?? "", albumArtist: values["albumArtist"], year: year,
            genre: values["genre"] ?? "", duration: player.duration, trackNumber: number("track"), discNumber: number("disc"),
            lyrics: values["lyrics"]), artwork: art)
    }
}
