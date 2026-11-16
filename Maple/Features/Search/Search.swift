import SwiftUI

struct Search: View {
    @Environment(LibraryStore.self) private var library
    @State private var query = ""
    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tracks: [LibraryTrack] { term.isEmpty ? [] : library.tracks.filter { "\($0.title) \($0.artist) \($0.album)".localizedStandardContains(term) } }
    private var albums: [LibraryAlbum] { term.isEmpty ? [] : library.albums.filter { "\($0.name) \($0.artist)".localizedStandardContains(term) } }
    private var artists: [LibraryArtist] { term.isEmpty ? [] : library.artists.filter { $0.name.localizedStandardContains(term) } }
    private var playlists: [LibraryPlaylist] { term.isEmpty ? [] : library.playlists.filter { "\($0.name) \($0.description)".localizedStandardContains(term) } }
    var body: some View {
        let matchingTracks = tracks
        NavigationStack {
            List {
                if !matchingTracks.isEmpty { Section("Tracks") { ForEach(matchingTracks) { LibraryTrackRow(track: $0, queue: matchingTracks) } } }
                if !albums.isEmpty {
                    Section("Albums") { ForEach(albums) { album in
                        NavigationLink { AlbumDetailView(album: album) } label: {
                            HStack {
                                LibraryArtwork(reference: album.artwork).frame(width: 48, height: 48)
                                VStack(alignment: .leading) { Text(album.name); Text(album.artist).font(.caption).foregroundStyle(.secondary) }
                            }
                        }.modifier(LibraryGroupActions(name: album.name, kind: "Album", trackIDs: album.trackIDs))
                    } }
                }
                if !artists.isEmpty { Section("Artists") { ForEach(artists) { artist in NavigationLink(artist.name) { ArtistDetailView(artist: artist) } } } }
                if !playlists.isEmpty { Section("Playlists") { ForEach(playlists) { playlist in NavigationLink(playlist.name) { PlaylistDetailView(playlistID: playlist.id) } } } }
            }
            .overlay {
                if term.isEmpty { ContentUnavailableView("Search Your Music", systemImage: "magnifyingglass", description: Text("Find tracks, albums, artists and playlists in one place.")) }
                else if matchingTracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty { ContentUnavailableView.search(text: term) }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Tracks, albums, artists, playlists")
        }
    }
}
