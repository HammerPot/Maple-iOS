import SwiftUI

struct Albums: View {
    @Environment(LibraryStore.self) private var library
    private var sort = LibrarySortState("albums", default: AlbumSort.name)
    @State private var query = ""

    private var visible: [LibraryAlbum] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = term.isEmpty ? library.albums : library.albums.filter {
            $0.name.localizedStandardContains(term) || $0.artist.localizedStandardContains(term)
        }
        return sort.apply(matches)
    }

    var body: some View {
        let albums = visible
        ScrollView {
            LazyVGrid(columns: LibraryGrid.columns, spacing: 20) {
                ForEach(albums) { album in
                    NavigationLink(value: LibraryRoute.album(album.id)) { AlbumCard(album: album) }
                        .buttonStyle(.plain)
                        .contextMenu { LibraryGroupMenu(album: album) }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .overlay {
            if library.albums.isEmpty {
                ContentUnavailableView("No Albums Yet", systemImage: "square.stack",
                                       description: Text("Albums are organised automatically from your music’s tags."))
            } else if albums.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle("Albums")
        .searchable(text: $query, prompt: "Filter albums")
        .toolbar { LibrarySortMenu(state: sort) }
    }
}

struct AlbumDetailView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryActions.self) private var actions
    @Environment(\.openLibraryRoute) private var open
    let albumID: String
    private var sort = LibrarySortState("albumDetail", default: TrackSort.trackNumber)

    init(albumID: String) { self.albumID = albumID }

    var body: some View {
        if let album = library.album(albumID) {
            content(album)
        } else {
            ContentUnavailableView("Album Removed", systemImage: "square.stack")
        }
    }

    private func content(_ album: LibraryAlbum) -> some View {
        let tracks = sort.apply(library.tracks(ids: album.trackIDs))
        let discs = Set(tracks.map(\.discNumber).filter { $0 > 0 })
        let byDisc = sort.key == .trackNumber && discs.count > 1
        let artistID = album.artist == "Various Artists" ? nil : library.artist(LibraryTrack.key(album.artist))?.id
        return List {
            Section {
                LibraryDetailHeader(title: album.name, subtitle: album.artist,
                                    detail: [album.genreLabel(tracks), album.year > 0 ? String(album.year) : nil].compactMap { $0 }.joined(separator: " · "),
                                    tracks: tracks) {
                    LibraryArtwork(reference: album.artwork, size: 280, cornerRadius: 12)
                }
                if let artistID {
                    Button("More by \(album.artist)", systemImage: "music.mic") { open(.artist(artistID)) }
                        .font(.subheadline)
                }
            }
            if byDisc {
                ForEach(discs.sorted(), id: \.self) { disc in
                    Section("Disc \(disc)") {
                        ForEach(tracks.filter { $0.discNumber == disc }) { row($0, album: album, queue: tracks) }
                    }
                }
            } else {
                Section {
                    ForEach(tracks) { row($0, album: album, queue: tracks) }
                } footer: {
                    Text(LibraryText.summary(tracks: tracks.count, duration: album.duration))
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                LibrarySortMenu(state: sort, options: [.trackNumber, .title, .duration])
                Menu("More", systemImage: "ellipsis") { LibraryGroupMenu(album: album) }
            }
        }
    }

    private func row(_ track: LibraryTrack, album: LibraryAlbum, queue: [LibraryTrack]) -> some View {
        LibraryTrackRow(track: track, queue: queue, number: track.trackNumber,
                        showsArtist: album.artist == "Various Artists" || LibraryTrack.key(track.artist) != LibraryTrack.key(album.artist))
    }
}

private extension LibraryAlbum {
    func genreLabel(_ tracks: [LibraryTrack]) -> String? {
        let genre = tracks.lazy.map(\.genre).first { $0 != "Unknown Genre" }
        return genre
    }
}
