import SwiftUI
import PhotosUI

/// Create (no `playlist`) or edit a playlist's name, description and artwork.
struct PlaylistEditor: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    var playlist: LibraryPlaylist?
    var initialTrackIDs: [UUID] = []
    var didSave: ((UUID) -> Void)?
    @State private var name = ""
    @State private var description = ""
    @State private var photo: PhotosPickerItem?
    @State private var newArtwork: UIImage?
    @State private var newArtworkData: Data?
    @State private var useAutomaticArtwork = false
    @State private var saving = false
    @State private var loadingPhoto = false
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        artworkPreview
                            .frame(width: 180, height: 180)
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    HStack {
                        PhotosPicker(selection: $photo, matching: .images) {
                            Label(newArtwork == nil && playlist?.artwork == nil ? "Choose Photo" : "Change Photo", systemImage: "photo")
                        }
                        if hasCustomArtwork {
                            Spacer()
                            Button("Use Automatic", systemImage: "square.grid.2x2") {
                                newArtwork = nil; newArtworkData = nil; photo = nil; useAutomaticArtwork = true
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    if loadingPhoto { ProgressView("Loading photo…") }
                }
                Section {
                    TextField("Playlist Name", text: $name).focused($nameFocused).submitLabel(.done)
                    TextField("Description", text: $description, axis: .vertical).lineLimit(2...6)
                } footer: {
                    if playlist == nil, !initialTrackIDs.isEmpty {
                        Text("\(LibraryActions.tracks(initialTrackIDs.count)) will be added.")
                    }
                }
            }
            .navigationTitle(playlist == nil ? "New Playlist" : "Edit Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(playlist == nil ? "Create" : "Save") { Task { await save() } }
                        .disabled(saving || loadingPhoto || trimmedName.isEmpty)
                }
            }
            .interactiveDismissDisabled(saving)
            .onAppear {
                name = playlist?.name ?? ""
                description = playlist?.description ?? ""
                if playlist == nil { nameFocused = true }
            }
            .task(id: photo) { await loadPhoto() }
        }
    }

    private var hasCustomArtwork: Bool { newArtwork != nil || (playlist?.artwork != nil && !useAutomaticArtwork) }

    @ViewBuilder private var artworkPreview: some View {
        if let newArtwork {
            Color.clear
                .overlay { Image(uiImage: newArtwork).resizable().scaledToFill() }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
        } else if let playlist {
            PlaylistArtwork(playlist: useAutomaticArtwork ? playlist.withoutCustomArtwork : playlist, size: 180, cornerRadius: 12)
        } else {
            PlaylistArtwork(playlist: LibraryPlaylist(id: UUID(), name: "", description: "", trackIDs: initialTrackIDs,
                                                      dateCreated: .now, dateModified: .now), size: 180, cornerRadius: 12)
        }
    }

    private func loadPhoto() async {
        guard let photo else { return }
        loadingPhoto = true
        defer { loadingPhoto = false }
        do {
            guard let data = try await photo.loadTransferable(type: Data.self) else { return }
            // Store a bounded JPEG rather than an arbitrarily large original.
            let prepared = await Task.detached { Self.prepare(data) }.value
            guard let prepared else { toasts.show("That photo couldn’t be used."); return }
            newArtworkData = prepared.data; newArtwork = prepared.image; useAutomaticArtwork = false
        } catch is CancellationError {
        } catch { toasts.show(error) }
    }

    private nonisolated static func prepare(_ data: Data) -> (data: Data, image: UIImage)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1200,
              ] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cgImage)
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
        return (jpeg, image)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let id: UUID
            if let playlist {
                id = playlist.id
                try library.updatePlaylist(id, name: name, description: description)
            } else {
                id = try library.createPlaylist(name: name, description: description, trackIDs: initialTrackIDs)
            }
            if let newArtworkData { try await library.setPlaylistArtwork(id, data: newArtworkData) }
            else if useAutomaticArtwork { try await library.setPlaylistArtwork(id, data: nil) }
            dismiss()
            didSave?(id)
        } catch { toasts.show(error) }
    }
}

/// Choose a playlist (or create one) for the given tracks.
struct AddToPlaylistSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    let trackIDs: [UUID]
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { creating = true } label: {
                        Label("New Playlist…", systemImage: "plus")
                    }
                }
                Section {
                    ForEach(library.playlists.sorted { $0.dateModified > $1.dateModified }) { playlist in
                        let contained = trackIDs.allSatisfy(playlist.trackIDs.contains)
                        Button { add(to: playlist) } label: {
                            HStack(spacing: 12) {
                                PlaylistArtwork(playlist: playlist, size: 48, cornerRadius: 6).frame(width: 48, height: 48)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name).foregroundStyle(.primary)
                                    Text(contained ? "Already added" : LibraryActions.tracks(playlist.trackIDs.count))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if contained { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .disabled(contained)
                    }
                }
            }
            .navigationTitle(trackIDs.count == 1 ? "Add to Playlist" : "Add \(trackIDs.count) Tracks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $creating) {
                PlaylistEditor(initialTrackIDs: trackIDs, didSave: { id in
                    toasts.show("Added to “\(library.playlist(id)?.name ?? "playlist")”")
                    dismiss()
                })
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func add(to playlist: LibraryPlaylist) {
        let added = library.addTracks(trackIDs, to: playlist.id)
        let skipped = trackIDs.count - added
        toasts.show(skipped > 0 && added > 0
                    ? "Added \(LibraryActions.tracks(added)) to “\(playlist.name)”. \(skipped) already there."
                    : "Added to “\(playlist.name)”")
        dismiss()
    }
}

/// Multi-select picker of library tracks not yet in the playlist.
struct PlaylistTrackPicker: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    let playlistID: UUID
    @State private var selected = Set<UUID>()
    @State private var query = ""

    private var available: [LibraryTrack] {
        let existing = Set(library.playlist(playlistID)?.trackIDs ?? [])
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return TrackSort.title.sorted(library.tracks.filter {
            !existing.contains($0.id) && (term.isEmpty || $0.title.localizedStandardContains(term)
                || $0.artist.localizedStandardContains(term) || $0.album.localizedStandardContains(term))
        }, descending: false)
    }

    var body: some View {
        let tracks = available
        NavigationStack {
            List(tracks, selection: $selected) { track in
                HStack(spacing: 12) {
                    LibraryArtwork(reference: track.artwork, size: 40).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).lineLimit(1)
                        Text("\(track.artist) · \(track.album)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            .listStyle(.plain)
            .environment(\.editMode, .constant(.active))
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Title, artist or album")
            .overlay {
                if tracks.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView("Everything’s Already Here", systemImage: "music.note.list",
                                               description: Text("Every track in your library is in this playlist."))
                    } else { ContentUnavailableView.search(text: query) }
                }
            }
            .navigationTitle(selected.isEmpty ? "Add Tracks" : "\(selected.count) Selected")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        // Keep library order for a predictable result.
                        library.addTracks(library.tracks.lazy.map(\.id).filter(selected.contains), to: playlistID)
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }
}

private extension LibraryPlaylist {
    var withoutCustomArtwork: LibraryPlaylist {
        var copy = self
        copy.artwork = nil
        return copy
    }
}
