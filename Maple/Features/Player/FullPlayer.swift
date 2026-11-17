import SwiftUI
import AVKit

struct FullPlayer: View {
    @Environment(PlaybackController.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryActions.self) private var actions
    @Environment(\.openLibraryRoute) private var open
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var panel: Panel?
    private enum Panel: String, Identifiable { case queue, lyrics; var id: Self { self } }
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                PlayerArtwork().frame(maxWidth: 240).padding(.top)
                VStack(spacing: 8) {
                    Text(player.currentItem?.title ?? "Nothing Playing").font(.headline).multilineTextAlignment(.center)
                    Text(player.currentItem?.artist ?? "Choose a track from your library").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                PlaybackScrubber()
                PlayerTransport()
                if player.playingFromMusic { Text("Playing from Music").font(.footnote).foregroundStyle(.secondary) }
                HStack {
                    Button("Up Next", systemImage: "list.bullet") { panel = .queue }
                    Spacer()
                    AirPlayPicker().frame(width: 44, height: 44).accessibilityLabel("AirPlay")
                    Spacer()
                    Button("Lyrics", systemImage: "quote.bubble") { panel = .lyrics }
                }.buttonStyle(.borderless)
                Button("Stop", systemImage: "stop.fill") { player.stop() }
                if player.currentItem?.source == .appleMusic {
                    Button("Open in Music", systemImage: "music.note") { if let url = URL(string: "music://") { openURL(url) } }
                }
            }
            .padding().frame(maxWidth: 600).frame(maxWidth: .infinity)
        }
        .navigationTitle("Now Playing").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) { PlayerTrackMenu() }
        }
        .sheet(item: $panel) { panel in
            NavigationStack {
                Group { switch panel { case .queue: UpNextView(); case .lyrics: LyricsPanel() } }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { self.panel = nil } } }
            }
        }
    }
}

private struct PlayerTrackMenu: View {
    @Environment(PlaybackController.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryActions.self) private var actions
    @Environment(\.openLibraryRoute) private var open
    var body: some View {
        Menu("Track Actions", systemImage: "ellipsis.circle") {
            if let id = player.currentItem?.libraryID, let track = library.track(id) {
                Button("Add to Playlist…", systemImage: "text.badge.plus") { actions.addToPlaylist([id]) }
                if let album = library.album(for: track) { Button("Go to Album", systemImage: "square.stack") { open(.album(album.id)) } }
                if let artist = library.artist(for: track) { Button("Go to Artist", systemImage: "music.mic") { open(.artist(artist.id)) } }
            } else { Text("No local track selected") }
        }
    }
}
private struct PlayerTransport: View {
    @Environment(PlaybackController.self) private var player
    var body: some View {
        HStack(spacing: 12) {
            Button("Shuffle", systemImage: "shuffle") { player.setShuffle(!player.queue.shuffled) }
                .symbolVariant(player.queue.shuffled ? .circle.fill : .none)
                .accessibilityValue(player.queue.shuffled ? "On" : "Off")
                .disabled(player.playingFromMusic)
            Spacer(minLength: 0)
            Button("Previous Track", systemImage: "backward.circle.fill") { Task { await player.previous() } }.font(.largeTitle)
            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.circle.fill" : "play.circle.fill") {
                if player.isPlaying { player.pause() } else { Task { await player.resume() } }
            }.font(.largeTitle)
            Button("Next Track", systemImage: "forward.circle.fill") { Task { await player.next() } }.font(.largeTitle)
            Spacer(minLength: 0)
            Button("Repeat", systemImage: player.queue.repeatMode == .one ? "repeat.1" : "repeat") { player.setRepeat(player.queue.repeatMode.next) }
                .symbolVariant(player.queue.repeatMode == .off ? .none : .circle.fill)
                .accessibilityValue(player.queue.repeatMode.rawValue.capitalized)
                .disabled(player.playingFromMusic)
        }.labelStyle(.iconOnly).buttonStyle(PlayerControlButtonStyle())
            .frame(minHeight: 44)
    }
}
private struct AirPlayPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(); view.prioritizesVideoDevices = false; return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) { uiView.tintColor = .label }
}

/// Keep the existing symbols and tint while giving transport controls full touch targets.
private struct PlayerControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .foregroundStyle(.tint)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
