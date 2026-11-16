import SwiftUI

struct Playlists: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.openLibraryRoute) private var open
    private var sort = LibrarySortState("playlists", default: PlaylistSort.modified)
    @State private var creating = false

    var body: some View {
        let playlists = sort.apply(library.playlists)
        ScrollView {
            LazyVGrid(columns: LibraryGrid.columns, spacing: 20) {
                Button { creating = true } label: { NewPlaylistCard() }
                    .buttonStyle(.plain)
                ForEach(playlists) { playlist in
                    NavigationLink(value: LibraryRoute.playlist(playlist.id)) { PlaylistCard(playlist: playlist) }
                        .buttonStyle(.plain)
                        .contextMenu { PlaylistMenu(playlist: playlist) }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .navigationTitle("Playlists")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                LibrarySortMenu(state: sort)
                Button("New Playlist", systemImage: "plus") { creating = true }
            }
        }
        .sheet(isPresented: $creating) {
            PlaylistEditor(didSave: { open(.playlist($0)) })
        }
    }
}

private struct NewPlaylistCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.tint.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay { Image(systemName: "plus").font(.largeTitle.weight(.medium)).foregroundStyle(.tint) }
            Text("New Playlist").font(.subheadline.weight(.medium)).padding(.top, 2)
            Text(" ").font(.subheadline)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New Playlist")
        .accessibilityAddTraits(.isButton)
    }
}

struct PlaylistCard: View {
    let playlist: LibraryPlaylist
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PlaylistArtwork(playlist: playlist, size: LibraryGrid.cardArtwork)
            Text(playlist.name).font(.subheadline.weight(.medium)).lineLimit(1).padding(.top, 2)
            Text(LibraryActions.tracks(playlist.trackIDs.count)).font(.subheadline).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(playlist.name), \(LibraryActions.tracks(playlist.trackIDs.count))")
    }
}

/// Custom artwork if set; otherwise a 2×2 mosaic of distinct track artwork, falling back to
/// the first track's artwork.
struct PlaylistArtwork: View {
    @Environment(LibraryStore.self) private var library
    let playlist: LibraryPlaylist
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 10

    private var mosaic: [String] {
        var seen: [String] = []
        for id in playlist.trackIDs {
            guard let artwork = library.track(id)?.artwork, !seen.contains(artwork) else { continue }
            seen.append(artwork)
            if seen.count == 4 { break }
        }
        return seen
    }

    var body: some View {
        if let artwork = playlist.artwork {
            LibraryArtwork(reference: artwork, size: size, cornerRadius: cornerRadius, placeholder: "music.note.list")
        } else {
            let references = mosaic
            if references.count == 4 {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow { tile(references[0]); tile(references[1]) }
                    GridRow { tile(references[2]); tile(references[3]) }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .accessibilityHidden(true)
            } else {
                LibraryArtwork(reference: references.first, size: size, cornerRadius: cornerRadius, placeholder: "music.note.list")
            }
        }
    }

    private func tile(_ reference: String) -> some View {
        LibraryArtwork(reference: reference, size: size / 2, cornerRadius: 0)
    }
}

struct PlaylistMenu: View {
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryActions.self) private var actions
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.openLibraryRoute) private var open
    let playlist: LibraryPlaylist
    var onEdit: (() -> Void)?
    var body: some View {
        let tracks = library.tracks(ids: playlist.trackIDs)
        Section {
            Button("Play", systemImage: "play") { LibraryPlayback.play(tracks) }.disabled(tracks.isEmpty)
            Button("Shuffle", systemImage: "shuffle") { LibraryPlayback.play(tracks, shuffle: true) }.disabled(tracks.isEmpty)
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { LibraryPlayback.enqueue(tracks, next: true) }.disabled(tracks.isEmpty)
            Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { LibraryPlayback.enqueue(tracks, next: false) }.disabled(tracks.isEmpty)
        }
        Section {
            if let onEdit { Button("Edit Details", systemImage: "pencil", action: onEdit) }
            Button("Duplicate", systemImage: "plus.square.on.square") {
                do {
                    if let copy = try library.duplicatePlaylist(playlist.id) { open(.playlist(copy)) }
                } catch { toasts.show(error) }
            }
        }
        Section {
            Button("Delete Playlist", systemImage: "trash", role: .destructive) { actions.delete(playlist: playlist) }
        }
    }
}

struct PlaylistDetailView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryActions.self) private var actions
    let playlistID: UUID
    private var sort = LibrarySortState("playlistDetail", default: TrackSort.playlistOrder)
    @State private var editing = false
    @State private var picking = false
    @State private var editMode = EditMode.inactive

    init(playlistID: UUID) { self.playlistID = playlistID }

    var body: some View {
        if let playlist = library.playlist(playlistID) {
            content(playlist)
        } else {
            ContentUnavailableView("Playlist Removed", systemImage: "music.note.list")
        }
    }

    private func content(_ playlist: LibraryPlaylist) -> some View {
        let ordered = library.tracks(ids: playlist.trackIDs)
        let tracks = sort.apply(ordered)
        let canReorder = sort.key == .playlistOrder && !sort.descending
        return List {
            Section {
                LibraryDetailHeader(title: playlist.name,
                                    detail: LibraryText.summary(tracks: ordered.count, duration: ordered.reduce(0) { $0 + $1.duration }),
                                    description: playlist.description, tracks: tracks) {
                    PlaylistArtwork(playlist: playlist, size: 280, cornerRadius: 12)
                }
                Button("Add Tracks", systemImage: "plus") { picking = true }
            }
            Section {
                ForEach(tracks) { track in
                    LibraryTrackRow(track: track, queue: tracks, playlist: playlist)
                }
                .onMove(perform: canReorder ? { library.moveTracks(in: playlist.id, fromOffsets: $0, toOffset: $1) } : nil)
                .onDelete { offsets in actions.remove(offsets.map { tracks[$0] }, from: playlist) }
            } footer: {
                if tracks.isEmpty {
                    Text("Add tracks from your library, or long-press any track and choose Add to Playlist.")
                }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if canReorder && !tracks.isEmpty {
                    Button(editMode.isEditing ? "Done" : "Reorder", systemImage: editMode.isEditing ? "checkmark" : "arrow.up.arrow.down.square") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                }
                LibrarySortMenu(state: sort, options: [.playlistOrder, .title, .artist, .album, .year, .duration])
                Menu("More", systemImage: "ellipsis") { PlaylistMenu(playlist: playlist, onEdit: { editing = true }) }
            }
        }
        .sheet(isPresented: $editing) { PlaylistEditor(playlist: playlist) }
        .sheet(isPresented: $picking) { PlaylistTrackPicker(playlistID: playlist.id) }
    }
}
