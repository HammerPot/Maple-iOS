import SwiftUI

/// One search across tracks, albums, artists and playlists, grouped by kind.
/// (The previous Search screen only searched the local library; there was no Apple Music search to keep.)
struct Search: View {
    var body: some View {
        LibraryNavigationStack { SearchResults() }
    }
}

private enum SearchScope: String, CaseIterable, Identifiable {
    case all = "All", tracks = "Tracks", albums = "Albums", artists = "Artists", playlists = "Playlists"
    var id: Self { self }
}

private struct SearchResults: View {
    @Environment(LibraryStore.self) private var library
    @State private var query = ""
    @State private var scope = SearchScope.all

    private static let preview = 5

    var body: some View {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let results = LibrarySearch(library: library, term: term)
        List {
            if !results.artists.isEmpty && (scope == .all || scope == .artists) {
                Section("Artists") {
                    ForEach(limit(results.artists)) { artist in
                        NavigationLink(value: LibraryRoute.artist(artist.id)) {
                            HStack(spacing: 12) {
                                LibraryArtwork(reference: artist.artwork, size: 44, cornerRadius: 22, placeholder: "music.mic").frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(artist.name)
                                    Text(Artists.counts(artist)).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                        .contextMenu { LibraryGroupMenu(artist: artist) }
                    }
                    more(results.artists.count, .artists)
                }
            }
            if !results.albums.isEmpty && (scope == .all || scope == .albums) {
                Section("Albums") {
                    ForEach(limit(results.albums)) { album in
                        NavigationLink(value: LibraryRoute.album(album.id)) {
                            HStack(spacing: 12) {
                                LibraryArtwork(reference: album.artwork, size: 44).frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.name).lineLimit(1)
                                    Text(album.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                        .contextMenu { LibraryGroupMenu(album: album) }
                    }
                    more(results.albums.count, .albums)
                }
            }
            if !results.playlists.isEmpty && (scope == .all || scope == .playlists) {
                Section("Playlists") {
                    ForEach(limit(results.playlists)) { playlist in
                        NavigationLink(value: LibraryRoute.playlist(playlist.id)) {
                            HStack(spacing: 12) {
                                PlaylistArtwork(playlist: playlist, size: 44, cornerRadius: 6).frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name).lineLimit(1)
                                    Text(LibraryActions.tracks(playlist.trackIDs.count)).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                        .contextMenu { PlaylistMenu(playlist: playlist) }
                    }
                    more(results.playlists.count, .playlists)
                }
            }
            if !results.tracks.isEmpty && (scope == .all || scope == .tracks) {
                Section("Tracks") {
                    let shown = limit(results.tracks)
                    ForEach(shown) { LibraryTrackRow(track: $0, queue: shown) }
                    more(results.tracks.count, .tracks)
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if term.isEmpty {
                ContentUnavailableView("Search Your Library", systemImage: "magnifyingglass",
                                       description: Text("Find tracks, albums, artists and playlists."))
            } else if results.isEmpty(in: scope) {
                ContentUnavailableView.search(text: term)
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Tracks, albums, artists, playlists")
        .searchScopes($scope, activation: .onSearchPresentation) {
            ForEach(SearchScope.allCases) { Text($0.rawValue).tag($0) }
        }
    }

    private func limit<Item>(_ items: [Item]) -> [Item] {
        scope == .all ? Array(items.prefix(Self.preview)) : items
    }

    @ViewBuilder private func more(_ count: Int, _ target: SearchScope) -> some View {
        if scope == .all && count > Self.preview {
            Button("Show All \(count) \(target.rawValue)") { withAnimation { scope = target } }
                .font(.subheadline)
        }
    }
}

/// Case- and diacritic-insensitive substring search over the library.
struct LibrarySearch {
    let tracks: [LibraryTrack]
    let albums: [LibraryAlbum]
    let artists: [LibraryArtist]
    let playlists: [LibraryPlaylist]

    @MainActor init(library: LibraryStore, term: String) {
        guard !term.isEmpty else { tracks = []; albums = []; artists = []; playlists = []; return }
        func matches(_ fields: String...) -> Bool { fields.contains { $0.localizedStandardContains(term) } }
        tracks = TrackSort.title.sorted(library.tracks.filter { matches($0.title, $0.artist, $0.album) }, descending: false)
        albums = library.albums.filter { matches($0.name, $0.artist) }
        artists = library.artists.filter { matches($0.name) }
        playlists = library.playlists.filter { matches($0.name, $0.description) }
    }

    fileprivate func isEmpty(in scope: SearchScope) -> Bool {
        switch scope {
        case .all: tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty
        case .tracks: tracks.isEmpty
        case .albums: albums.isEmpty
        case .artists: artists.isEmpty
        case .playlists: playlists.isEmpty
        }
    }
}
