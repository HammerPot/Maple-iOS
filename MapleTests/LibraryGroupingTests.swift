import Foundation
import Testing
@testable import Maple

struct LibraryGroupingTests {
    private func track(_ title: String, artist: String = "Artist", album: String = "Album", albumArtist: String? = nil,
                       year: Int = 0, disc: Int = 0, number: Int = 0, duration: Double = 60, added: Date = .now,
                       artwork: String? = nil) -> LibraryTrack {
        LibraryTrack(fileName: "\(UUID().uuidString).mp3", title: title, artist: artist, album: album, albumArtist: albumArtist,
                     year: year, duration: duration, trackNumber: number, discNumber: disc, artwork: artwork, dateAdded: added)
    }

    @Test func albumTracksOrderByDiscThenNumberWithUntaggedLast() throws {
        let tracks = [track("C", disc: 2, number: 1), track("Z"), track("B", disc: 1, number: 2), track("A", disc: 1, number: 1)]
        let album = try #require(LibraryGrouping.albums(from: tracks).first)
        #expect(album.trackIDs == [tracks[3].id, tracks[2].id, tracks[0].id, tracks[1].id])
        #expect(album.duration == 240)
    }

    @Test func sameTitleWithDifferentArtistsSplitsButACompilationAlbumArtistMerges() {
        let tracks = [track("1", artist: "A", album: "Greatest Hits", albumArtist: "A"),
                      track("2", artist: "B", album: "Greatest Hits", albumArtist: "B"),
                      track("3", artist: "C", album: "Now 99", albumArtist: "Various Artists"),
                      track("4", artist: "D", album: "now 99 ", albumArtist: "Various Artists")]
        let albums = LibraryGrouping.albums(from: tracks)
        #expect(albums.count == 3)
        #expect(albums.filter { $0.name == "Greatest Hits" }.map(\.artist).sorted() == ["A", "B"])
        #expect(albums.first { $0.name == "Now 99" }?.artist == "Various Artists")
    }

    @Test func unknownValuesFallBackAndGroupTogether() {
        let tracks = [LibraryTrack(fileName: "song one.mp3", title: "  ", artist: "", album: ""),
                      LibraryTrack(fileName: "two.m4a", title: "Two", artist: " ", album: "\n")]
        #expect(tracks[0].title == "song one")
        #expect(tracks.allSatisfy { $0.artist == "Unknown Artist" && $0.album == "Unknown Album" })
        #expect(LibraryGrouping.albums(from: tracks).count == 1)
        #expect(LibraryGrouping.artists(from: tracks).map(\.name) == ["Unknown Artist"])
    }

    @Test func artistsMergeCaseAndAccentVariantsAndListNewestAlbumsFirst() throws {
        let tracks = [track("1", artist: "Beyoncé", album: "Old", year: 2003, artwork: "images/a.image"),
                      track("2", artist: "beyonce", album: "New", year: 2016)]
        let artists = LibraryGrouping.artists(from: tracks)
        #expect(artists.count == 1)
        let artist = try #require(artists.first)
        #expect(artist.albumIDs == [tracks[1].albumKey, tracks[0].albumKey])
        #expect(artist.artwork == "images/a.image")
    }

    @Test func sortKeysAndDirections() {
        let old = Date(timeIntervalSince1970: 0)
        let tracks = [track("b", artist: "Zed", year: 1999, duration: 30, added: old),
                      track("A", artist: "amy", year: 2020, duration: 300, added: .now),
                      track("c10", artist: "Amy", year: 2020, duration: 90, added: old.addingTimeInterval(5)),
                      track("c9", artist: "Bob", year: 2010, duration: 90, added: old.addingTimeInterval(1))]
        #expect(TrackSort.title.sorted(tracks, descending: false).map(\.title) == ["A", "b", "c9", "c10"])
        #expect(TrackSort.title.sorted(tracks, descending: true).map(\.title) == ["c10", "c9", "b", "A"])
        #expect(TrackSort.artist.sorted(tracks, descending: false).map(\.title) == ["A", "c10", "c9", "b"])
        #expect(TrackSort.dateAdded.sorted(tracks, descending: true).map(\.title) == ["A", "c10", "c9", "b"])
        #expect(TrackSort.duration.sorted(tracks, descending: false).first?.title == "b")
        #expect(TrackSort.year.defaultDescending && TrackSort.dateAdded.defaultDescending && !TrackSort.title.defaultDescending)
        let albums = LibraryGrouping.albums(from: [track("1", album: "Beta", year: 2001), track("2", album: "alpha", year: 2010)])
        #expect(AlbumSort.name.sorted(albums, descending: false).map(\.name) == ["alpha", "Beta"])
        #expect(AlbumSort.year.sorted(albums, descending: true).map(\.name) == ["alpha", "Beta"])
    }

    @Test func sortChoiceIsRememberedPerScreen() {
        let defaults = UserDefaults.standard
        let keys = ["albums", "artists"].flatMap { ["library.sort.\($0).key", "library.sort.\($0).descending"] }
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        keys.forEach(defaults.removeObject)
        let albums = LibrarySortState("albums", default: AlbumSort.name)
        let artists = LibrarySortState("artists", default: ArtistSort.name)
        albums.select(.year)
        #expect(defaults.string(forKey: "library.sort.albums.key") == "year")
        #expect(defaults.bool(forKey: "library.sort.albums.descending"))
        #expect(defaults.string(forKey: "library.sort.artists.key") == nil)
        #expect(artists.key == .name)
        albums.select(.year) // choosing the same key again flips direction
        #expect(!defaults.bool(forKey: "library.sort.albums.descending"))
    }
}
