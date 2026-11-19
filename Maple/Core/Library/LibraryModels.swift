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
    /// An album is its title plus its album artist; without an album-artist tag the track's own
    /// lead artist stands in, so two artists' "Greatest Hits" are never one album while a track
    /// crediting a guest ("A feat. B") stays on A's album. Compilations are grouped through an
    /// album artist ("Various Artists"), which the metadata reader sets from the compilation flag.
    var albumKey: String { Self.key(album) + "\u{0}" + Self.key(albumArtist ?? Self.leadArtist(artist)) }
    /// The credited lead artist: "A feat. B", "A ft. B" and "A (featuring B)" give "A". Joined
    /// names ("A & B", "A, B") are left whole because they are often a single act.
    static func leadArtist(_ artist: String) -> String {
        guard let guest = artist.range(of: #"\s[(\[]?(?:feat\.?|ft\.?|featuring)\s"#, options: [.regularExpression, .caseInsensitive]) else { return artist }
        let lead = artist[..<guest.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return lead.isEmpty ? artist : lead
    }
    var artistKey: String { Self.key(artist) }
}

/// The legacy player and Apple Music code still say `Song`; it is the library track.
typealias Song = LibraryTrack

/// Derived from tracks on every change; never stored.
struct LibraryAlbum: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let artist: String
    let artwork: String?
    let year: Int
    /// Disc, then track number order.
    let trackIDs: [UUID]
    let duration: Double
    /// Most recent `dateAdded` of its tracks.
    let dateAdded: Date
}

/// Derived from tracks on every change; never stored.
struct LibraryArtist: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let artwork: String?
    let trackIDs: [UUID]
    /// Newest first.
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
    /// Rows dropped while decoding; never written back.
    var skippedRows = 0
}

/// Decodes an array element by element: a malformed element is counted and skipped instead
/// of failing the whole array.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element] = []
    var skipped = 0
    /// Accepts any JSON value (object, array, string, number, bool, null), so a damaged row of any shape can be skipped.
    private struct Placeholder: Decodable {
        init(from decoder: Decoder) throws { _ = decoder }
    }
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            do { elements.append(try container.decode(Element.self)) }
            catch {
                skipped += 1
                // A failed decode does not advance the container; consume the element.
                _ = try container.decode(Placeholder.self)
            }
        }
    }
}

struct LibraryImportSummary: Sendable, Equatable {
    var imported = 0
    var duplicates = 0
    var failures: [String] = []
    var cancelled = false
    var isEmpty: Bool { imported == 0 && duplicates == 0 && failures.isEmpty && !cancelled }
}

struct LibraryImportProgress: Sendable {
    var completed: Int
    var total: Int
    var fileName: String
}

enum LibraryError: LocalizedError {
    case unsupportedVersion(Int), busy, notLoaded, invalidName, unreadableAudio, unsafePath, notAudio
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "This library was saved by a newer Maple version (\(version)). Update Maple to open it."
        case .busy: "Wait for the current library operation to finish."
        case .notLoaded: "The library is not ready. Try loading it again."
        case .invalidName: "Enter a playlist name."
        case .unreadableAudio: "This file is not playable audio on this device."
        case .unsafePath: "The library contains an invalid file reference."
        case .notAudio: "This is not an audio file."
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
        let tracks = try container.decode(LossyArray<LibraryTrack>.self, forKey: .tracks)
        let playlists = try container.decodeIfPresent(LossyArray<LibraryPlaylist>.self, forKey: .playlists)
        self.tracks = tracks.elements
        self.playlists = playlists?.elements ?? []
        skippedRows = tracks.skipped + (playlists?.skipped ?? 0)
        statistics = try container.decodeIfPresent([UUID: TrackStatistics].self, forKey: .statistics) ?? [:]
        recentlyPlayed = try container.decodeIfPresent([UUID].self, forKey: .recentlyPlayed) ?? []
        pendingFileRemovals = try container.decodeIfPresent([String].self, forKey: .pendingFileRemovals) ?? []
    }
}
