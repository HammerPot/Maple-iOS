import SwiftUI

struct Artists: View {
    @Environment(LibraryStore.self) private var library
    @AppStorage("library.sort.artists") private var sort = "Name"
    private var sorted: [LibraryArtist] {
        library.artists.sorted { sort == "Track Count" ? $0.trackIDs.count > $1.trackIDs.count : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        List(sorted) { artist in
            NavigationLink { ArtistDetailView(artist: artist) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(artist.name).font(.headline)
                    Text("\(artist.albumIDs.count) albums · \(artist.trackIDs.count) tracks").font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            }.modifier(LibraryGroupActions(name: artist.name, kind: "Artist", trackIDs: artist.trackIDs))
        }
        .overlay { if sorted.isEmpty { ContentUnavailableView("No Artists Yet", systemImage: "music.mic") } }
        .navigationTitle("Artists")
        .toolbar { LibrarySortMenu(selection: $sort, options: ["Name", "Track Count"]) }
    }
}

struct ArtistDetailView: View {
    @Environment(LibraryStore.self) private var library
    let artist: LibraryArtist
    @AppStorage("library.sort.artistDetail.tracks") private var sort = "Title"
    private var current: LibraryArtist? { library.artists.first { $0.id == artist.id } }
    private var tracks: [LibraryTrack] { LibrarySortMenu.tracks(library.tracks(ids: current?.trackIDs ?? []), by: sort) }
    var body: some View {
        List {
            if let current {
                Section { LibraryPlayButtons(tracks: tracks) }
                Section("Albums") {
                    ForEach(library.albums.filter { current.albumIDs.contains($0.id) }) { album in
                        NavigationLink { AlbumDetailView(album: album) } label: {
                            HStack {
                                LibraryArtwork(reference: album.artwork).frame(width: 56, height: 56)
                                VStack(alignment: .leading) { Text(album.name); Text(album.artist).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                Section("Tracks") { ForEach(tracks) { LibraryTrackRow(track: $0, queue: tracks) } }
            } else { ContentUnavailableView("Artist Removed", systemImage: "music.mic") }
        }
        .navigationTitle(artist.name)
        .toolbar { LibrarySortMenu(selection: $sort, options: ["Title", "Album", "Year", "Duration"]); if let current { GroupActionMenu(name: current.name, kind: "Artist", trackIDs: current.trackIDs) } }
    }
}
