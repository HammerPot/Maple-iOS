import SwiftUI

struct NowPlayingBar: View {
    @Environment(PlaybackController.self) private var player
    @Environment(\.openURL) private var openURL
    @Binding var showPlayer: Bool
    var body: some View {
        HStack(spacing: 8) {
            Button { showPlayer = true } label: {
                HStack(spacing: 12) {
                    PlayerArtwork().frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.currentItem?.title ?? "No song playing").font(.caption).lineLimit(1)
                            .foregroundStyle(Color(uiColor: .label))
                        Text(player.currentItem?.artist ?? "Artist").font(.caption).lineLimit(1)
                            .foregroundStyle(Color(uiColor: .secondaryLabel))
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.currentItem.map { "Now playing: \($0.title), \($0.artist). Open player" } ?? "Open player")
            if player.isLoading { ProgressView().accessibilityLabel("Loading track") }
            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill", action: toggle)
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            Button("Next Track", systemImage: "forward.fill") { Task { await player.next() } }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            if player.currentItem?.source == .appleMusic {
                Button("Open Music", systemImage: "music.note") { if let url = URL(string: "music://") { openURL(url) } }
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color(uiColor: .label))
        .padding(.horizontal, 16).padding(.vertical, 4)
    }
    private func toggle() {
        if player.isPlaying { player.pause() } else { Task { await player.resume() } }
    }
}
