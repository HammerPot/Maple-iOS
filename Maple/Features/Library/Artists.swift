import SwiftUI

struct Artists: View {
    @Environment(LibraryStore.self) private var library
    private var sort = LibrarySortState("artists", default: ArtistSort.name)
    @State private var query = ""

    private var visible: [LibraryArtist] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return sort.apply(term.isEmpty ? library.artists : library.artists.filter { $0.name.localizedStandardContains(term) })
    }

    var body: some View {
        let artists = visible
        List(artists) { artist in
            NavigationLink(value: LibraryRoute.artist(artist.id)) {
                HStack(spacing: 12) {
                    LibraryArtwork(reference: artist.artwork, size: 48, cornerRadius: 24, placeholder: "music.mic")
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artist.name).lineLimit(1)
                        Text(Self.counts(artist)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .contextMenu { LibraryGroupMenu(artist: artist) }
        }
        .listStyle(.plain)
        .overlay {
            if library.artists.isEmpty {
                ContentUnavailableView("No Artists Yet", systemImage: "music.mic",
                                       description: Text("Artists appear here when you add music."))
            } else if artists.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle("Artists")
        .searchable(text: $query, prompt: "Filter artists")
        .toolbar { LibrarySortMenu(state: sort) }
    }

    static func counts(_ artist: LibraryArtist) -> String {
        let albums = artist.albumIDs.count == 1 ? "1 album" : "\(artist.albumIDs.count) albums"
        return "\(albums) · \(LibraryActions.tracks(artist.trackIDs.count))"
    }
}

struct ArtistDetailView: View {
    @Environment(LibraryStore.self) private var library
    let artistID: String
    private var sort = LibrarySortState("artistDetail", default: TrackSort.album)

    init(artistID: String) { self.artistID = artistID }

    var body: some View {
        if let artist = library.artist(artistID) {
            content(artist)
        } else {
            ContentUnavailableView("Artist Removed", systemImage: "music.mic")
        }
    }

    private func content(_ artist: LibraryArtist) -> some View {
        let tracks = sort.apply(library.tracks(ids: artist.trackIDs))
        let albums = artist.albumIDs.compactMap { library.album($0) }
        return List {
            Section {
                LibraryDetailHeader(title: artist.name, detail: Artists.counts(artist), tracks: tracks) {
                    LibraryArtwork(reference: artist.artwork, size: 180, cornerRadius: 90, placeholder: "music.mic")
                        .frame(maxWidth: 180)
                }
            }
            if !albums.isEmpty {
                Section("Albums") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(albums) { album in
                                NavigationLink(value: LibraryRoute.album(album.id)) {
                                    AlbumCard(album: album, subtitle: album.year > 0 ? String(album.year) : LibraryActions.tracks(album.trackIDs.count))
                                        .frame(width: 150)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { LibraryGroupMenu(album: album) }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            Section("Tracks") {
                ForEach(tracks) { LibraryTrackRow(track: $0, queue: tracks) }
            }
        }
        .listStyle(.plain)
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                LibrarySortMenu(state: sort, options: [.album, .title, .year, .duration, .dateAdded])
                Menu("More", systemImage: "ellipsis") { LibraryGroupMenu(artist: artist) }
            }
        }
    }
}
