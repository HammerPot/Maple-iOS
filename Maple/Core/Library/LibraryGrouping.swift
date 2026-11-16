import Foundation

/// Pure derivation of albums and artists from tracks. Nothing here is persisted.
enum LibraryGrouping {
    /// Albums are keyed by title plus album artist when that tag exists. Tracks without an
    /// album-artist tag group by title alone, so untagged compilations stay together while
    /// unrelated albums that merely share a title (and are tagged) are kept apart.
    static func albums(from tracks: [LibraryTrack]) -> [LibraryAlbum] {
        Dictionary(grouping: tracks, by: \.albumKey).map { key, songs in
            let ordered = songs.sorted(by: albumOrder)
            let first = ordered[0]
            let artists = Set(songs.map { LibraryTrack.key($0.artist) })
            let artist = first.albumArtist ?? (artists.count == 1 ? first.artist : "Various Artists")
            return LibraryAlbum(id: key, name: first.album, artist: artist,
                                artwork: ordered.lazy.compactMap(\.artwork).first,
                                year: ordered.lazy.map(\.year).first { $0 > 0 } ?? 0,
                                trackIDs: ordered.map(\.id),
                                duration: songs.reduce(0) { $0 + $1.duration },
                                dateAdded: songs.lazy.map(\.dateAdded).max() ?? .distantPast)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Disc, then track number, then title. Untagged numbers (0) sort after tagged ones.
    static func albumOrder(_ lhs: LibraryTrack, _ rhs: LibraryTrack) -> Bool {
        func rank(_ value: Int) -> Int { value > 0 ? value : .max }
        if lhs.discNumber != rhs.discNumber { return rank(lhs.discNumber) < rank(rhs.discNumber) }
        if lhs.trackNumber != rhs.trackNumber { return rank(lhs.trackNumber) < rank(rhs.trackNumber) }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}
