import SwiftUI
import Observation

/// Shared presentation state for row and card actions.
///
/// Rows only *request* "add to playlist" or "delete"; one presenter at the root shows the sheet
/// or confirmation. This keeps thousands of rows free of their own sheets and dialogs.
@MainActor @Observable
final class LibraryActions {
    struct PlaylistRequest: Identifiable {
        let id = UUID()
        let trackIDs: [UUID]
    }

    /// A destructive action awaiting confirmation. The copy says exactly what will go.
    struct Confirmation: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let button: String
        let perform: @MainActor (LibraryStore) async throws -> Void
    }

    var addingToPlaylist: PlaylistRequest?
    var confirmation: Confirmation?

    func addToPlaylist(_ trackIDs: [UUID]) {
        guard !trackIDs.isEmpty else { return }
        addingToPlaylist = PlaylistRequest(trackIDs: trackIDs)
    }

    func delete(track: LibraryTrack) {
        confirmation = Confirmation(
            title: "Delete Track?",
            message: "“\(track.title)” will be permanently deleted from this device, along with its play history. It will be removed from any playlists.",
            button: "Delete Track") { try await $0.deleteTracks([track.id]) }
    }

    func delete(album: LibraryAlbum) {
        confirmation = Confirmation(
            title: "Delete Album?",
            message: "“\(album.name)” by \(album.artist) and its \(Self.tracks(album.trackIDs.count)) will be permanently deleted from this device, along with their play history and any artwork no other track uses. They will be removed from any playlists.",
            button: "Delete Album") { try await $0.deleteTracks(Set(album.trackIDs)) }
    }

    func delete(artist: LibraryArtist) {
        confirmation = Confirmation(
            title: "Delete Artist?",
            message: "All \(Self.tracks(artist.trackIDs.count)) by “\(artist.name)” will be permanently deleted from this device, along with their play history and any artwork no other track uses. They will be removed from any playlists.",
            button: "Delete Artist") { try await $0.deleteTracks(Set(artist.trackIDs)) }
    }

    func delete(playlist: LibraryPlaylist) {
        confirmation = Confirmation(
            title: "Delete Playlist?",
            message: "“\(playlist.name)” will be permanently deleted. Its tracks will stay in your library.",
            button: "Delete Playlist") { try await $0.deletePlaylist(playlist.id) }
    }

    func remove(_ tracks: [LibraryTrack], from playlist: LibraryPlaylist) {
        guard !tracks.isEmpty else { return }
        let what = tracks.count == 1 ? "“\(tracks[0].title)”" : Self.tracks(tracks.count)
        confirmation = Confirmation(
            title: tracks.count == 1 ? "Remove Track?" : "Remove \(tracks.count) Tracks?",
            message: "\(what) will be removed from “\(playlist.name)”. \(tracks.count == 1 ? "It stays" : "They stay") in your library.",
            button: "Remove") { $0.removeTracks(Set(tracks.map(\.id)), from: playlist.id) }
    }

    func clearRecentlyPlayed() {
        confirmation = Confirmation(
            title: "Clear Recently Played?",
            message: "Your recently played list will be emptied. Your music and listening stats are kept.",
            button: "Clear") { $0.clearRecentlyPlayed() }
    }

    nonisolated static func tracks(_ count: Int) -> String { count == 1 ? "1 track" : "\(count) tracks" }
}

private struct LibraryActionPresenter: ViewModifier {
    @Environment(LibraryStore.self) private var library
    @Environment(ToastCenter.self) private var toasts
    @State private var actions = LibraryActions()

    func body(content: Content) -> some View {
        content
            .environment(actions)
            .sheet(item: $actions.addingToPlaylist) { request in
                AddToPlaylistSheet(trackIDs: request.trackIDs)
                    .environment(actions)
            }
            .alert(actions.confirmation?.title ?? "", isPresented: Binding(
                get: { actions.confirmation != nil },
                set: { if !$0 { actions.confirmation = nil } }
            ), presenting: actions.confirmation) { confirmation in
                Button(confirmation.button, role: .destructive) {
                    Task {
                        do { try await confirmation.perform(library) }
                        catch { toasts.show(error) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { confirmation in
                Text(confirmation.message)
            }
    }
}

extension View {
    /// Installs the shared `LibraryActions` and its sheet/confirmation. Apply once, at the root.
    func libraryActionPresenter() -> some View { modifier(LibraryActionPresenter()) }
}
