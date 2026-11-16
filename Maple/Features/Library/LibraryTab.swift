import SwiftUI

struct LibraryTab: View {
    var body: some View {
        LibraryNavigationStack {
            LibraryOverview()
        }
    }
}

private struct LibraryOverview: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.openLibraryRoute) private var open

    var body: some View {
        List {
            Section {
                category("Playlists", systemImage: "music.note.list", count: library.playlists.count, route: .playlists)
                category("Artists", systemImage: "music.mic", count: library.artists.count, route: .artists)
                category("Albums", systemImage: "square.stack", count: library.albums.count, route: .albums)
                category("Tracks", systemImage: "music.note", count: library.tracks.count, route: .tracks)
                category("Listening Stats", systemImage: "chart.bar", count: nil, route: .stats)
            }
            if library.isLoaded && library.tracks.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("Make It Yours", systemImage: "music.note")
                    } description: {
                        Text("Add files or a folder of music to build your library.")
                    } actions: { MusicButton(style: .prominent) }
                }
                .listRowBackground(Color.clear)
            } else if !recentAlbums.isEmpty {
                Section {
                    LazyVGrid(columns: LibraryGrid.columns, spacing: 20) {
                        ForEach(recentAlbums) { album in
                            // A Button, not a NavigationLink: inside a List row a link would add a chevron.
                            Button { open(.album(album.id)) } label: { AlbumCard(album: album) }
                                .buttonStyle(.plain)
                                .contextMenu { LibraryGroupMenu(album: album) }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    Text("Recently Added").font(.title2.bold()).foregroundStyle(.primary).textCase(nil)
                }
            }
            Section {
                NavigationLink(value: LibraryRoute.acknowledgements) {
                    Label("Acknowledgements", systemImage: "doc.text")
                }
                .font(.subheadline)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Library")
        .toolbar { ToolbarItem(placement: .primaryAction) { MusicButton() } }
    }

    private var recentAlbums: [LibraryAlbum] {
        Array(AlbumSort.dateAdded.sorted(library.albums, descending: true).prefix(12))
    }

    private func category(_ title: String, systemImage: String, count: Int?, route: LibraryRoute) -> some View {
        NavigationLink(value: route) {
            LabeledContent {
                if let count { Text(count.formatted()) }
            } label: {
                Label(title, systemImage: systemImage)
            }
        }
        .font(.title3)
    }
}
