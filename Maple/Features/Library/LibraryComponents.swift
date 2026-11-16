import SwiftUI

struct LibraryArtwork: View {
    @Environment(LibraryStore.self) private var library
    var reference: String?
    var pixels = 160
    @State private var data: Data?
    var body: some View {
        ArtworkView(data: data)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityIgnoresInvertColors()
            .task(id: "\(reference ?? ""): \(pixels)") {
                data = nil
                if let url = library.artworkURL(reference) { data = await library.artworkCache.thumbnail(at: url, pixels: pixels) }
            }
    }
}

struct LibraryTrackRow: View {
    @Environment(LibraryStore.self) private var library
    let track: LibraryTrack
    var queue: [LibraryTrack] = []
    var removeFromPlaylist: (() -> Void)?
    @State private var adding = false
    @State private var deleting = false
    @Environment(ToastCenter.self) private var toasts
    var body: some View {
        Button { LibraryPlayback.play(queue.isEmpty ? [track] : queue, startingAt: track.id) } label: {
            HStack(spacing: 12) {
                LibraryArtwork(reference: track.artwork).frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).foregroundStyle(.primary).lineLimit(1)
                    Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(MapleFormat.duration(track.duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }.padding(.vertical, 2).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button("Play", systemImage: "play") { LibraryPlayback.play([track]) }
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { LibraryPlayback.enqueue([track], next: true) }
            Button("Add to Queue", systemImage: "text.badge.plus") { LibraryPlayback.enqueue([track], next: false) }
            Button("Add to Playlist", systemImage: "text.badge.plus") { adding = true }
            if let removeFromPlaylist { Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive, action: removeFromPlaylist) }
            Button("Delete Track", systemImage: "trash", role: .destructive) { deleting = true }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let removeFromPlaylist { Button("Remove", systemImage: "minus.circle", role: .destructive, action: removeFromPlaylist) }
            else { Button("Delete", systemImage: "trash", role: .destructive) { deleting = true } }
        }
        .swipeActions(edge: .leading) { Button("Add to Playlist", systemImage: "text.badge.plus") { adding = true }.tint(.accentColor) }
        .accessibilityAction(named: "Add to Playlist") { adding = true }
        .accessibilityAction(named: "Delete Track") { deleting = true }
        .sheet(isPresented: $adding) { AddToPlaylistSheet(trackIDs: [track.id]) }
        .confirmationDialog("Delete “\(track.title)”?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete Track", role: .destructive) {
                Task { do { try await library.deleteTracks([track.id]) } catch { toasts.show(error) } }
            }
        } message: { Text("This removes the audio file, its listening history and this track from every playlist. Artwork used only by this track is also removed.") }
    }
}

/// Deliberately small adapter for the next player implementation.
@MainActor enum LibraryPlayback {
    static func play(_ tracks: [LibraryTrack], startingAt id: UUID? = nil, shuffle: Bool = false) {
        let queue = shuffle ? tracks.shuffled() : tracks
        guard !queue.isEmpty else { return }
        AudioPlayerManager.shared.setQueue(queue, startingAt: id.flatMap { id in queue.firstIndex { $0.id == id } } ?? 0)
        AudioPlayerManager.shared.play()
    }
    static func enqueue(_ tracks: [LibraryTrack], next: Bool) { AudioPlayerManager.shared.enqueueLibraryTracks(tracks, next: next) }
}

struct LibraryPlayButtons: View {
    let tracks: [LibraryTrack]
    var body: some View {
        HStack {
            Button("Play", systemImage: "play.fill") { LibraryPlayback.play(tracks) }.buttonStyle(.borderedProminent)
            Button("Shuffle", systemImage: "shuffle") { LibraryPlayback.play(tracks, shuffle: true) }.buttonStyle(.bordered)
        }.disabled(tracks.isEmpty)
    }
}

struct LibraryGroupActions: ViewModifier {
    @Environment(LibraryStore.self) private var library
    @Environment(ToastCenter.self) private var toasts
    let name: String
    let kind: String
    let trackIDs: [UUID]
    @State private var adding = false
    @State private var deleting = false
    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Play", systemImage: "play") { LibraryPlayback.play(library.tracks(ids: trackIDs)) }
            Button("Shuffle", systemImage: "shuffle") { LibraryPlayback.play(library.tracks(ids: trackIDs), shuffle: true) }
            Button("Add to Playlist", systemImage: "text.badge.plus") { adding = true }
            Button("Delete \(kind)", systemImage: "trash", role: .destructive) { deleting = true }
        }
        .accessibilityAction(named: "Add to Playlist") { adding = true }
        .accessibilityAction(named: "Delete \(kind)") { deleting = true }
        .sheet(isPresented: $adding) { AddToPlaylistSheet(trackIDs: trackIDs) }
        .confirmationDialog("Delete “\(name)”?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete \(trackIDs.count) Tracks", role: .destructive) {
                Task { do { try await library.deleteTracks(Set(trackIDs)) } catch { toasts.show(error) } }
            }
        } message: { Text("This deletes all \(trackIDs.count) tracks in this \(kind.lowercased()), their audio files, listening history and unused artwork, and removes them from every playlist.") }
    }
}

struct LibrarySortMenu: View {
    @Binding var selection: String
    var options = ["Title", "Artist", "Recently Added", "Duration"]
    var body: some View {
        Menu("Sort", systemImage: "arrow.up.arrow.down") {
            Picker("Sort by", selection: $selection) { ForEach(options, id: \.self) { Text($0) } }
        }
    }
    static func tracks(_ tracks: [LibraryTrack], by sort: String) -> [LibraryTrack] {
        tracks.sorted {
            switch sort {
            case "Artist": return $0.artist == $1.artist ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.artist.localizedStandardCompare($1.artist) == .orderedAscending
            case "Recently Added": return $0.dateAdded > $1.dateAdded
            case "Duration": return $0.duration > $1.duration
            case "Year": return $0.year > $1.year
            case "Album": return $0.album == $1.album ? $0.trackNumber < $1.trackNumber : $0.album.localizedStandardCompare($1.album) == .orderedAscending
            default: return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
    }
}
