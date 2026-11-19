import Foundation

/// Pure derivation of albums and artists from tracks. Nothing here is persisted.
enum LibraryGrouping {
    /// Albums are keyed by title plus album artist, falling back to the track artist (see
    /// `LibraryTrack.albumKey`). Unrelated albums that merely share a title stay apart;
    /// compilations stay together when they carry an album artist or the compilation flag.
    static func albums(from tracks: [LibraryTrack]) -> [LibraryAlbum] {
        Dictionary(grouping: tracks, by: \.albumKey).map { key, songs in
            let ordered = songs.sorted(by: albumOrder)
            let first = ordered[0]
            // Every track in a group shares the album artist or, failing that, the lead artist.
            let artist = ordered.lazy.compactMap(\.albumArtist).first ?? LibraryTrack.leadArtist(first.artist)
            return LibraryAlbum(id: key, name: first.album, artist: artist,
                                artwork: ordered.lazy.compactMap(\.artwork).first,
                                year: ordered.lazy.map(\.year).first { $0 > 0 } ?? 0,
                                trackIDs: ordered.map(\.id),
                                duration: songs.reduce(0) { $0 + $1.duration },
                                dateAdded: songs.lazy.map(\.dateAdded).max() ?? .distantPast)
        }
        .sorted { stableOrder($0.name, $1.name, $0.id, $1.id) }
    }

    /// Name order with the id as a tie-breaker, so equally named items keep one order across
    /// rebuilds (dictionary enumeration order is not stable).
    private static func stableOrder(_ lhs: String, _ rhs: String, _ lhsID: String, _ rhsID: String) -> Bool {
        let result = lhs.localizedStandardCompare(rhs)
        return result == .orderedSame ? lhsID < rhsID : result == .orderedAscending
    }

    static func artists(from tracks: [LibraryTrack]) -> [LibraryArtist] {
        Dictionary(grouping: tracks, by: { LibraryTrack.key($0.artist) }).map { key, songs in
            let ordered = songs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            var albumIDs: [String] = []
            for song in songs.sorted(by: { $0.year == $1.year ? $0.album < $1.album : $0.year > $1.year }) where !albumIDs.contains(song.albumKey) {
                albumIDs.append(song.albumKey)
            }
            return LibraryArtist(id: key, name: songs[0].artist, artwork: ordered.lazy.compactMap(\.artwork).first,
                                 trackIDs: ordered.map(\.id), albumIDs: albumIDs)
        }
        .sorted { stableOrder($0.name, $1.name, $0.id, $1.id) }
    }

    /// A run of an album's tracks that share a disc number; `disc` 0 means "no disc tag".
    struct DiscSection: Identifiable, Equatable {
        let disc: Int
        let tracks: [LibraryTrack]
        var id: Int { disc }
    }

    /// Splits already-ordered album tracks into disc sections in order of first appearance, so
    /// every track (including untagged ones) lands in exactly one section, whichever direction
    /// the list is sorted in.
    static func discSections(_ tracks: [LibraryTrack]) -> [DiscSection] {
        var order: [Int] = []
        var groups: [Int: [LibraryTrack]] = [:]
        for track in tracks {
            if groups[track.discNumber] == nil { order.append(track.discNumber) }
            groups[track.discNumber, default: []].append(track)
        }
        return order.map { DiscSection(disc: $0, tracks: groups[$0] ?? []) }
    }

    /// Disc, then track number, then title. Untagged numbers (0) sort after tagged ones.
    static func albumOrder(_ lhs: LibraryTrack, _ rhs: LibraryTrack) -> Bool {
        func rank(_ value: Int) -> Int { value > 0 ? value : .max }
        if lhs.discNumber != rhs.discNumber { return rank(lhs.discNumber) < rank(rhs.discNumber) }
        if lhs.trackNumber != rhs.trackNumber { return rank(lhs.trackNumber) < rank(rhs.trackNumber) }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}
