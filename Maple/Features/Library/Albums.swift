import SwiftUI

struct Albums: View {
    @Environment(LibraryStore.self) private var library
    @AppStorage("library.sort.albums") private var sort = "Title"
    private var sorted: [LibraryAlbum] {
        library.albums.sorted {
            switch sort {
            case "Artist": $0.artist.localizedStandardCompare($1.artist) == .orderedAscending
            case "Year": $0.year > $1.year
            default: $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 18)], spacing: 22) {
                ForEach(sorted) { album in
                    NavigationLink { AlbumDetailView(album: album) } label: { AlbumCard(album: album) }
                        .buttonStyle(.plain)
                        .modifier(LibraryGroupActions(name: album.name, kind: "Album", trackIDs: album.trackIDs))
                }
            }.padding()
        }
        .overlay { if sorted.isEmpty { ContentUnavailableView("No Albums Yet", systemImage: "square.stack", description: Text("Albums are organised automatically when you import music.")) } }
        .navigationTitle("Albums")
        .toolbar { LibrarySortMenu(selection: $sort, options: ["Title", "Artist", "Year"]) }
    }
}

struct AlbumCard: View {
    let album: LibraryAlbum
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            LibraryArtwork(reference: album.artwork, pixels: 480).aspectRatio(1, contentMode: .fit)
            Text(album.name).font(.headline).lineLimit(2)
            Text(album.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Text("\(album.trackIDs.count) tracks").font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
}

struct AlbumDetailView: View {
    @Environment(LibraryStore.self) private var library
    let album: LibraryAlbum
    @AppStorage("library.sort.albumDetail") private var sort = "Track Number"
    private var current: LibraryAlbum? { library.albums.first { $0.id == album.id } }
    private var tracks: [LibraryTrack] {
        let ordered = library.tracks(ids: current?.trackIDs ?? [])
        return sort == "Track Number" ? ordered : LibrarySortMenu.tracks(ordered, by: sort)
    }
    var body: some View {
        List {
            if let current {
                Section {
                    LibraryArtwork(reference: current.artwork, pixels: 900).aspectRatio(1, contentMode: .fit).frame(maxWidth: 320).frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(current.name).font(.title2.bold())
                        Text(current.artist).foregroundStyle(.secondary)
                        if current.year > 0 { Text(String(current.year)).font(.subheadline).foregroundStyle(.secondary) }
                        LibraryPlayButtons(tracks: tracks).padding(.top, 8)
                    }
                }
                ForEach(Array(Set(tracks.map(\.discNumber))).sorted(), id: \.self) { disc in
                    Section(disc > 0 ? "Disc \(disc)" : "Tracks") {
                        ForEach(tracks.filter { $0.discNumber == disc }) { track in LibraryTrackRow(track: track, queue: tracks) }
                    }
                }
            } else { ContentUnavailableView("Album Removed", systemImage: "square.stack") }
        }
        .navigationTitle(album.name).navigationBarTitleDisplayMode(.inline)
        .toolbar { LibrarySortMenu(selection: $sort, options: ["Track Number", "Title", "Duration"]); if let current { GroupActionMenu(name: current.name, kind: "Album", trackIDs: current.trackIDs) } }
    }
}

struct GroupActionMenu: View {
    let name: String
    let kind: String
    let trackIDs: [UUID]
    @Environment(LibraryStore.self) private var library
    @Environment(ToastCenter.self) private var toasts
    @State private var adding = false
    @State private var deleting = false
    var body: some View {
        Menu("\(kind) Actions", systemImage: "ellipsis.circle") {
            Button("Add to Playlist", systemImage: "text.badge.plus") { adding = true }
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { LibraryPlayback.enqueue(library.tracks(ids: trackIDs), next: true) }
            Button("Add to Queue", systemImage: "text.badge.plus") { LibraryPlayback.enqueue(library.tracks(ids: trackIDs), next: false) }
            Button("Delete \(kind)", systemImage: "trash", role: .destructive) { deleting = true }
        }
        .sheet(isPresented: $adding) { AddToPlaylistSheet(trackIDs: trackIDs) }
        .confirmationDialog("Delete “\(name)”?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete \(trackIDs.count) Tracks", role: .destructive) {
                Task { do { try await library.deleteTracks(Set(trackIDs)) } catch { toasts.show(error) } }
            }
        } message: { Text("This deletes all \(trackIDs.count) audio files in this \(kind.lowercased()), their listening history and unused artwork, and removes the tracks from every playlist.") }
    }
}
