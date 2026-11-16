import SwiftUI

struct Playlists: View {
    @Environment(LibraryStore.self) private var library
    @AppStorage("library.sort.playlists") private var sort = "Name"
    @State private var creating = false
    private var sorted: [LibraryPlaylist] {
        library.playlists.sorted { sort == "Recently Modified" ? $0.dateModified > $1.dateModified : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 18)], spacing: 22) {
                ForEach(sorted) { playlist in
                    NavigationLink { PlaylistDetailView(playlistID: playlist.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            PlaylistArtwork(playlist: playlist).aspectRatio(1, contentMode: .fit)
                            Text(playlist.name).font(.headline).lineLimit(2)
                            Text("\(playlist.trackIDs.count) tracks").font(.subheadline).foregroundStyle(.secondary)
                        }.accessibilityElement(children: .combine)
                    }.buttonStyle(.plain).modifier(PlaylistActions(playlist: playlist))
                }
            }.padding()
        }
        .overlay {
            if sorted.isEmpty {
                ContentUnavailableView { Label("Music for Every Mood", systemImage: "music.note.list") }
                description: { Text("Gather your favourites into a playlist.") }
                actions: { Button("Create Playlist") { creating = true }.buttonStyle(.borderedProminent) }
            }
        }
        .navigationTitle("Playlists")
        .toolbar {
            LibrarySortMenu(selection: $sort, options: ["Name", "Recently Modified"])
            Button("Create Playlist", systemImage: "plus") { creating = true }
        }
        .sheet(isPresented: $creating) { PlaylistEditor() }
    }
}

struct PlaylistArtwork: View {
    @Environment(LibraryStore.self) private var library
    let playlist: LibraryPlaylist
    private var references: [String] { Array(library.tracks(ids: playlist.trackIDs).compactMap(\.artwork).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(4)) }
    var body: some View {
        Group {
            if let artwork = playlist.artwork { LibraryArtwork(reference: artwork, pixels: 600) }
            else if references.count >= 4 {
                Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                    ForEach(0..<2) { row in
                        GridRow { ForEach(0..<2) { column in LibraryArtwork(reference: references[row * 2 + column], pixels: 300) } }
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 8))
            } else { LibraryArtwork(reference: references.first, pixels: 600) }
        }.accessibilityHidden(true)
    }
}

struct PlaylistDetailView: View {
    @Environment(LibraryStore.self) private var library
    let playlistID: UUID
    @AppStorage("library.sort.playlistDetail") private var sort = "Playlist Order"
    @State private var editing = false
    @State private var picking = false
    @State private var removing: [UUID] = []
    @State private var confirmingRemoval = false
    private var playlist: LibraryPlaylist? { library.playlist(playlistID) }
    private var visible: [LibraryTrack] {
        let ordered = library.tracks(ids: playlist?.trackIDs ?? [])
        return sort == "Playlist Order" ? ordered : LibrarySortMenu.tracks(ordered, by: sort)
    }
    var body: some View {
        let displayed = visible
        List {
            if let playlist {
                Section {
                    PlaylistArtwork(playlist: playlist).aspectRatio(1, contentMode: .fit).frame(maxWidth: 320).frame(maxWidth: .infinity)
                    Text(playlist.name).font(.title2.bold())
                    if !playlist.description.isEmpty { Text(playlist.description).foregroundStyle(.secondary) }
                    Text("\(playlist.trackIDs.count) tracks").font(.subheadline).foregroundStyle(.secondary)
                    LibraryPlayButtons(tracks: library.tracks(ids: playlist.trackIDs))
                    Button("Edit Details", systemImage: "pencil") { editing = true }
                    Button("Add Tracks", systemImage: "plus") { picking = true }
                }
                Section("Tracks") {
                    ForEach(displayed) { track in
                        LibraryTrackRow(track: track, queue: displayed, removeFromPlaylist: {
                            removing = [track.id]; confirmingRemoval = true
                        })
                        .moveDisabled(sort != "Playlist Order")
                    }
                    .onMove { indices, offset in
                        var ids = playlist.trackIDs
                        ids.move(fromOffsets: indices, toOffset: offset)
                        library.setPlaylistTracks(playlistID, ids: ids)
                    }
                    .onDelete { indices in
                        removing = indices.compactMap { displayed.indices.contains($0) ? displayed[$0].id : nil }
                        confirmingRemoval = true
                    }
                }
            } else { ContentUnavailableView("Playlist Removed", systemImage: "music.note.list") }
        }
        .navigationTitle(playlist?.name ?? "Playlist").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            LibrarySortMenu(selection: $sort, options: ["Playlist Order", "Title", "Artist", "Album", "Year", "Duration"])
            if let playlist { EditButton(); PlaylistActionMenu(playlist: playlist) }
        }
        .sheet(isPresented: $editing) { PlaylistEditor(playlist: playlist) }
        .sheet(isPresented: $picking) { PlaylistTrackPicker(playlistID: playlistID) }
        .confirmationDialog("Remove \(removing.count) tracks from this playlist?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove from Playlist", role: .destructive) {
                library.setPlaylistTracks(playlistID, ids: (playlist?.trackIDs ?? []).filter { !removing.contains($0) })
            }
        } message: { Text("The audio files and tracks in your library are kept.") }
    }
}

struct PlaylistActions: ViewModifier {
    let playlist: LibraryPlaylist
    @Environment(LibraryStore.self) private var library
    @Environment(ToastCenter.self) private var toasts
    @State private var deleting = false
    @State private var editing = false
    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Play", systemImage: "play") { LibraryPlayback.play(library.tracks(ids: playlist.trackIDs)) }
            Button("Edit Details", systemImage: "pencil") { editing = true }
            Button("Duplicate Playlist", systemImage: "doc.on.doc") { do { try library.duplicatePlaylist(playlist.id) } catch { toasts.show(error) } }
            Button("Delete Playlist", systemImage: "trash", role: .destructive) { deleting = true }
        }
        .sheet(isPresented: $editing) { PlaylistEditor(playlist: playlist) }
        .confirmationDialog("Delete “\(playlist.name)”?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) { Task { do { try await library.deletePlaylist(playlist.id) } catch { toasts.show(error) } } }
        } message: { Text("This removes the playlist and its unused custom artwork. Your tracks and audio files are kept.") }
    }
}

struct PlaylistActionMenu: View {
    let playlist: LibraryPlaylist
    @Environment(LibraryStore.self) private var library
    @Environment(ToastCenter.self) private var toasts
    @State private var deleting = false
    var body: some View {
        Menu("Playlist Actions", systemImage: "ellipsis.circle") {
            Button("Duplicate Playlist", systemImage: "doc.on.doc") { do { try library.duplicatePlaylist(playlist.id) } catch { toasts.show(error) } }
            Button("Delete Playlist", systemImage: "trash", role: .destructive) { deleting = true }
        }
        .confirmationDialog("Delete “\(playlist.name)”?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) { Task { do { try await library.deletePlaylist(playlist.id) } catch { toasts.show(error) } } }
        } message: { Text("This removes the playlist and its unused custom artwork. Your tracks and audio files are kept.") }
    }
}
