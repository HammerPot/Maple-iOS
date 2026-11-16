import SwiftUI

/// The seam between library screens and the player. Everything that starts or queues local
/// playback goes through here, so a new player only has to re-implement these three calls.
@MainActor enum LibraryPlayback {
    // Composition-root-installed commands keep existing library call sites independent of engines.
    static var start: (([LibraryTrack], UUID?, Bool) -> Void)?
    static var add: (([LibraryTrack], Bool) -> Void)?
    static func play(_ tracks: [LibraryTrack], startingAt id: UUID? = nil, shuffle: Bool = false) {
        start?(tracks, id, shuffle)
    }
    static func enqueue(_ tracks: [LibraryTrack], next: Bool) { add?(tracks, next) }
}

/// Square artwork from a library reference, decoded at display size off the main thread.
struct LibraryArtwork: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.displayScale) private var displayScale
    var reference: String?
    /// Largest side in points the image will be shown at.
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 6
    var placeholder = "music.note"
    @State private var loaded: UIImage?

    private var pixels: Int { Int((size * displayScale).rounded(.up)) }
    private var url: URL? { library.artworkURL(reference) }

    var body: some View {
        // Memory-cache lookup only; decoding happens in the task.
        let image = loaded ?? url.flatMap { library.artworkCache.cached($0, pixels: pixels) }
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay {
                            Image(systemName: placeholder)
                                .font(.system(size: max(12, size * 0.32)))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
            .task(id: "\(reference ?? "")@\(pixels)") {
                guard let url else { loaded = nil; return }
                loaded = await library.artworkCache.thumbnail(at: url, pixels: pixels)
            }
    }
}

/// Dense track row used everywhere a list of tracks appears.
struct LibraryTrackRow: View {
    @Environment(LibraryActions.self) private var actions
    @Environment(\.openLibraryRoute) private var open
    @Environment(LibraryStore.self) private var library
    let track: LibraryTrack
    /// The list the row belongs to; tapping plays it from this track.
    var queue: [LibraryTrack] = []
    /// Album screens show the track number instead of artwork.
    var number: Int?
    var showsArtist = true
    var playlist: LibraryPlaylist?
    var trailing: String?

    var body: some View {
        Button { LibraryPlayback.play(queue.isEmpty ? [track] : queue, startingAt: track.id) } label: {
            HStack(spacing: 12) {
                if let number {
                    Text(number > 0 ? "\(number)" : "–")
                        .font(.body.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(minWidth: 24, alignment: .trailing)
                } else {
                    LibraryArtwork(reference: track.artwork, size: 44).frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).lineLimit(1)
                    if showsArtist {
                        Text(number == nil ? "\(track.artist) · \(track.album)" : track.artist)
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(trailing ?? MapleFormat.duration(track.duration))
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(track.title), \(track.artist)")
        .accessibilityValue(MapleFormat.duration(track.duration))
        .accessibilityHint("Plays this track")
        .contextMenu { menu } preview: {
            // The preview is hosted outside this hierarchy and does not inherit
            // `@Environment` objects, so the store is passed in explicitly.
            TrackPreview(track: track).environment(library)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { LibraryPlayback.enqueue([track], next: true) }
                .tint(.accentColor)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let playlist {
                Button("Remove", systemImage: "minus.circle", role: .destructive) { actions.remove([track], from: playlist) }
            } else {
                Button("Delete", systemImage: "trash", role: .destructive) { actions.delete(track: track) }
            }
            Button("Add to Playlist", systemImage: "text.badge.plus") { actions.addToPlaylist([track.id]) }
                .tint(.indigo)
        }
        .accessibilityAction(named: "Play Next") { LibraryPlayback.enqueue([track], next: true) }
        .accessibilityAction(named: "Add to Queue") { LibraryPlayback.enqueue([track], next: false) }
        .accessibilityAction(named: "Add to Playlist") { actions.addToPlaylist([track.id]) }
        .accessibilityAction(named: playlist == nil ? "Delete Track" : "Remove from Playlist") {
            if let playlist { actions.remove([track], from: playlist) } else { actions.delete(track: track) }
        }
    }

    @ViewBuilder private var menu: some View {
        Section {
            Button("Play", systemImage: "play") { LibraryPlayback.play([track]) }
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { LibraryPlayback.enqueue([track], next: true) }
            Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { LibraryPlayback.enqueue([track], next: false) }
        }
        Section {
            Button("Add to Playlist…", systemImage: "text.badge.plus") { actions.addToPlaylist([track.id]) }
            if let album = library.album(for: track) {
                Button("Go to Album", systemImage: "square.stack") { open(.album(album.id)) }
            }
            if let artist = library.artist(for: track) {
                Button("Go to Artist", systemImage: "music.mic") { open(.artist(artist.id)) }
            }
        }
        Section {
            if let playlist {
                Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive) { actions.remove([track], from: playlist) }
            }
            Button("Delete from Library", systemImage: "trash", role: .destructive) { actions.delete(track: track) }
        }
    }
}

private struct TrackPreview: View {
    let track: LibraryTrack
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LibraryArtwork(reference: track.artwork, size: 240, cornerRadius: 10).frame(width: 240, height: 240)
            Text(track.title).font(.headline).lineLimit(2)
            Text("\(track.artist) · \(track.album)").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding()
        .frame(width: 272)
    }
}

/// Play and Shuffle, side by side, as on album and playlist headers.
struct LibraryPlayButtons: View {
    let tracks: [LibraryTrack]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        // Stacked at accessibility sizes so "Shuffle" never wraps mid-word.
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            Button { LibraryPlayback.play(tracks) } label: {
                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            Button { LibraryPlayback.play(tracks, shuffle: true) } label: {
                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .fontWeight(.semibold)
        .disabled(tracks.isEmpty)
    }
}

/// Grid columns that adapt from two on a phone to many on iPad.
enum LibraryGrid {
    static let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16, alignment: .top)]
    static let cardArtwork: CGFloat = 220
}

/// Artwork-forward card for albums and playlists.
struct LibraryCard: View {
    let title: String
    let subtitle: String
    var artwork: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LibraryArtwork(reference: artwork, size: LibraryGrid.cardArtwork, cornerRadius: 10)
            Text(title).font(.subheadline.weight(.medium)).lineLimit(1).padding(.top, 2)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(subtitle)")
    }
}

struct AlbumCard: View {
    let album: LibraryAlbum
    var subtitle: String?
    var body: some View {
        LibraryCard(title: album.name, subtitle: subtitle ?? album.artist, artwork: album.artwork)
    }
}

/// Context menu shared by album and artist cards and rows.
struct LibraryGroupMenu: View {
    @Environment(LibraryActions.self) private var actions
    @Environment(LibraryStore.self) private var library
    var album: LibraryAlbum?
    var artist: LibraryArtist?
    private var trackIDs: [UUID] { album?.trackIDs ?? artist?.trackIDs ?? [] }
    var body: some View {
        Section {
            Button("Play", systemImage: "play") { LibraryPlayback.play(library.tracks(ids: trackIDs)) }
            Button("Shuffle", systemImage: "shuffle") { LibraryPlayback.play(library.tracks(ids: trackIDs), shuffle: true) }
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { LibraryPlayback.enqueue(library.tracks(ids: trackIDs), next: true) }
            Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { LibraryPlayback.enqueue(library.tracks(ids: trackIDs), next: false) }
        }
        Section {
            Button("Add to Playlist…", systemImage: "text.badge.plus") { actions.addToPlaylist(trackIDs) }
        }
        Section {
            if let album {
                Button("Delete Album", systemImage: "trash", role: .destructive) { actions.delete(album: album) }
            } else if let artist {
                Button("Delete Artist", systemImage: "trash", role: .destructive) { actions.delete(artist: artist) }
            }
        }
    }
}

/// A small header block: big artwork, title, subtitle lines and Play/Shuffle.
struct LibraryDetailHeader<Artwork: View>: View {
    let title: String
    var subtitle: String?
    var detail: String?
    var description: String?
    let tracks: [LibraryTrack]
    @ViewBuilder var artwork: Artwork
    var body: some View {
        VStack(spacing: 6) {
            artwork
                .frame(maxWidth: 280)
                .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                .padding(.bottom, 8)
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            if let subtitle { Text(subtitle).font(.title3).foregroundStyle(.tint).multilineTextAlignment(.center) }
            if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            if let description, !description.isEmpty {
                Text(description).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 2)
            }
            LibraryPlayButtons(tracks: tracks).padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
    }
}

enum LibraryText {
    static func summary(tracks count: Int, duration: Double) -> String {
        let seconds = max(0, duration.isFinite ? duration : 0)
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds < 60 ? [.seconds] : [.hours, .minutes]
        let length = Duration.seconds(seconds)
            .formatted(.units(allowed: units, width: .wide, maximumUnitCount: 2))
        return "\(LibraryActions.tracks(count)), \(length)"
    }
}
