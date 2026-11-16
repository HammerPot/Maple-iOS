import SwiftUI
import PhotosUI

struct PlaylistEditor: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    var playlist: LibraryPlaylist?
    var initialTrackIDs: [UUID] = []
    var didCreate: ((UUID) -> Void)?
    @State private var name = ""
    @State private var description = ""
    @State private var photo: PhotosPickerItem?
    @State private var artwork: Data?
    @State private var removeArtwork = false
    @State private var saving = false
    @State private var loadingPhoto = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Playlist name", text: $name)
                    TextField("Description", text: $description, axis: .vertical).lineLimit(3...6)
                }
                Section("Artwork") {
                    if let artwork { ArtworkView(data: artwork).aspectRatio(1, contentMode: .fit).frame(maxWidth: 240) }
                    else if let playlist, !removeArtwork { PlaylistArtwork(playlist: playlist).aspectRatio(1, contentMode: .fit).frame(maxWidth: 240) }
                    PhotosPicker(selection: $photo, matching: .images) { Label("Choose Photo", systemImage: "photo") }
                    if loadingPhoto { ProgressView("Loading photo…") }
                    if artwork != nil || playlist?.artwork != nil {
                        Button("Use Automatic Artwork") { artwork = nil; photo = nil; removeArtwork = true }
                    }
                }
            }
            .navigationTitle(playlist == nil ? "New Playlist" : "Edit Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving || loadingPhoto || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(saving)
            .task { name = playlist?.name ?? ""; description = playlist?.description ?? "" }
            .task(id: photo) {
                guard let photo else { return }
                loadingPhoto = true
                defer { loadingPhoto = false }
                do { artwork = try await photo.loadTransferable(type: Data.self); removeArtwork = false }
                catch is CancellationError { }
                catch { toasts.show(error) }
            }
        }
    }
    private func save() async {
        saving = true; defer { saving = false }
        do {
            let id: UUID
            if let playlist { id = playlist.id; try library.updatePlaylist(id, name: name, description: description) }
            else { id = try library.createPlaylist(name: name, description: description, trackIDs: initialTrackIDs) }
            if artwork != nil || removeArtwork { try await library.setPlaylistArtwork(id, data: artwork) }
            try await library.flush(); didCreate?(id); dismiss()
        } catch { toasts.show(error) }
    }
}

struct AddToPlaylistSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    let trackIDs: [UUID]
    @State private var creating = false
    var body: some View {
        NavigationStack {
            List {
                Button("New Playlist", systemImage: "plus") { creating = true }
                ForEach(library.playlists) { playlist in
                    Button {
                        library.addTracks(trackIDs, to: playlist.id)
                        toasts.show("Added to “\(playlist.name)”"); dismiss()
                    } label: {
                        HStack {
                            PlaylistArtwork(playlist: playlist).frame(width: 48, height: 48)
                            VStack(alignment: .leading) {
                                Text(playlist.name)
                                Text("\(playlist.trackIDs.count) tracks").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $creating) {
                PlaylistEditor(initialTrackIDs: trackIDs, didCreate: { _ in dismiss() })
            }
        }
    }
}

struct PlaylistTrackPicker: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let playlistID: UUID
    @State private var selected = Set<UUID>()
    @State private var query = ""
    private var available: [LibraryTrack] {
        let existing = Set(library.playlist(playlistID)?.trackIDs ?? [])
        return LibrarySortMenu.tracks(library.tracks.filter {
            !existing.contains($0.id) && (query.isEmpty || "\($0.title) \($0.artist)".localizedStandardContains(query))
        }, by: "Title")
    }
    var body: some View {
        NavigationStack {
            List(available, selection: $selected) { track in
                HStack {
                    LibraryArtwork(reference: track.artwork).frame(width: 44, height: 44)
                    VStack(alignment: .leading) { Text(track.title); Text(track.artist).font(.caption).foregroundStyle(.secondary) }
                }.tag(track.id)
            }
            .environment(\.editMode, .constant(.active))
            .searchable(text: $query, prompt: "Find tracks to add")
            .overlay { if available.isEmpty { ContentUnavailableView("No Tracks to Add", systemImage: "music.note.list", description: Text("Import more music or change your search.")) } }
            .navigationTitle("Add Tracks")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(selected.count)") { library.addTracks(library.tracks.filter { selected.contains($0.id) }.map(\.id), to: playlistID); dismiss() }.disabled(selected.isEmpty)
                }
            }
        }
    }
}
