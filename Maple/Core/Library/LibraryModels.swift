import Foundation

struct LibraryTrack: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var fileName: String
    var title: String
    var artist: String
    var album: String
    var albumArtist: String?
    var year: Int
    var genre: String
    var duration: Double
    var trackNumber: Int
    var discNumber: Int
    var artwork: String?
    var dateAdded: Date
    /// Unmodified embedded text, including LRC timestamps when present.
    var lyrics: String?

    init(id: UUID = UUID(), fileName: String, title: String, artist: String = "Unknown Artist",
         album: String = "Unknown Album", albumArtist: String? = nil, year: Int = 0,
         genre: String = "Unknown Genre", duration: Double = 0, trackNumber: Int = 0,
         discNumber: Int = 0, artwork: String? = nil, dateAdded: Date = .now, lyrics: String? = nil) {
        self.id = id; self.fileName = URL(fileURLWithPath: fileName).lastPathComponent
        self.title = Self.label(title, fallback: URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent)
        self.artist = Self.label(artist, fallback: "Unknown Artist")
        self.album = Self.label(album, fallback: "Unknown Album")
        self.albumArtist = albumArtist.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.year = year; self.genre = Self.label(genre, fallback: "Unknown Genre")
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.trackNumber = max(0, trackNumber); self.discNumber = max(0, discNumber)
        self.artwork = artwork; self.dateAdded = dateAdded; self.lyrics = lyrics
    }
    static func label(_ value: String, fallback: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? fallback : clean
    }
    static func key(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    var duplicateKey: String { Self.key(title) + "\u{0}" + Self.key(artist) }
    var albumKey: String { Self.key(album) + "\u{0}" + Self.key(albumArtist ?? "") }
    // Compatibility for the legacy player. Resolve storage through LibraryStore for new code.
    var ext: String { URL(fileURLWithPath: fileName).pathExtension }
    var url: URL { URL(fileURLWithPath: fileName) }
}

typealias Song = LibraryTrack

struct LibraryAlbum: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let artist: String
    let artwork: String?
    let year: Int
    let trackIDs: [UUID]
}

struct LibraryArtist: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let trackIDs: [UUID]
    let albumIDs: [String]
}

struct LibraryPlaylist: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var description: String
    var artwork: String?
    var trackIDs: [UUID]
    var dateCreated: Date
    var dateModified: Date
}

struct TrackStatistics: Codable, Hashable, Sendable {
    var plays = 0
    var completions = 0
    var skips = 0
    var listeningSeconds: Double = 0
    var lastPlayed: Date?
}

struct LibraryCatalog: Codable, Sendable {
    var version = 1
    var revision: UInt64 = 0
    var migratedLegacy = true
    var tracks: [LibraryTrack] = []
    var playlists: [LibraryPlaylist] = []
    var statistics: [UUID: TrackStatistics] = [:]
    var recentlyPlayed: [UUID] = []
    var pendingFileRemovals: [String] = []
}

struct LibraryImportSummary: Sendable {
    var imported = 0
    var duplicates = 0
    var failures: [String] = []
    var cancelled = false
    var message: String {
        "\(imported) imported · \(duplicates) duplicates skipped · \(failures.count) failed" + (cancelled ? " · Cancelled" : "")
    }
}

struct LibraryImportProgress: Sendable {
    var completed: Int
    var total: Int
    var fileName: String
}

enum LibraryError: LocalizedError {
    case unsupportedVersion(Int), busy, notLoaded, invalidName, unreadableAudio, unsafePath
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "This library was saved by a newer Maple version (\(version)). Update Maple to open it."
        case .busy: "Wait for the current library operation to finish."
        case .notLoaded: "The library is not ready. Try loading it again."
        case .invalidName: "Enter a playlist name."
        case .unreadableAudio: "This file is not playable audio on this device."
        case .unsafePath: "The library contains an invalid file reference."
        }
    }
}

extension LibraryCatalog {
    private enum CodingKeys: String, CodingKey {
        case version, revision, migratedLegacy, tracks, playlists, statistics, recentlyPlayed, pendingFileRemovals
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        revision = try container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        migratedLegacy = try container.decodeIfPresent(Bool.self, forKey: .migratedLegacy) ?? true
        tracks = try container.decode([LibraryTrack].self, forKey: .tracks)
        playlists = try container.decodeIfPresent([LibraryPlaylist].self, forKey: .playlists) ?? []
        statistics = try container.decodeIfPresent([UUID: TrackStatistics].self, forKey: .statistics) ?? [:]
        recentlyPlayed = try container.decodeIfPresent([UUID].self, forKey: .recentlyPlayed) ?? []
        pendingFileRemovals = try container.decodeIfPresent([String].self, forKey: .pendingFileRemovals) ?? []
    }
}
