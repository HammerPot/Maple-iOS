import Foundation

struct PlaybackItem: Codable, Hashable, Sendable {
    enum Source: String, Codable, Sendable { case local, appleMusic }
    var source: Source
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var audioURL: URL?
    var artworkURL: URL?
    var libraryID: UUID?

    @MainActor init(track: LibraryTrack, library: LibraryStore) {
        source = .local; id = track.id.uuidString; title = track.title; artist = track.artist
        album = track.album; duration = track.duration; audioURL = library.audioURL(for: track)
        artworkURL = library.artworkURL(track.artwork); libraryID = track.id
    }

    init(source: Source, id: String, title: String, artist: String = "", album: String = "",
         duration: Double = 0, audioURL: URL? = nil, artworkURL: URL? = nil) {
        self.source = source; self.id = id; self.title = title; self.artist = artist; self.album = album
        self.duration = duration; self.audioURL = audioURL; self.artworkURL = artworkURL
    }
}

struct PlaybackEntry: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var item: PlaybackItem
}

enum PlaybackRepeat: String, Codable, CaseIterable, Sendable {
    case off, all, one
    var next: Self { switch self { case .off: .all; case .all: .one; case .one: .off } }
}
