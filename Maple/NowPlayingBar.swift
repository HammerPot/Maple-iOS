import SwiftUI

struct NowPlayingBar: View {
    @ObservedObject private var audioManager = AudioPlayerManager.shared
    @ObservedObject private var amPlayer = AMPlayer.shared
    @Binding var showPlayer: Bool

    private var usesAppleMusic: Bool { amPlayer.initialized }
    private var playing: Bool { usesAppleMusic ? amPlayer.isPlaying : audioManager.isPlaying }
    private var artwork: PlatformImage? {
        if usesAppleMusic { return amPlayer.albumArt }
        guard let path = audioManager.currentSong?.artwork else { return nil }
        return PlatformImage(contentsOfFile: MapleLibrary.directory.appending(path: path).path)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                showPlayer = true
            } label: {
                HStack(spacing: 12) {
                    Group {
                        if let artwork { Image(platformImage: artwork).resizable() }
                        else { Image("Maple").resizable() }
                    }
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .clipShape(.rect(cornerRadius: 8))
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(usesAppleMusic ? amPlayer.title : audioManager.currentSong?.title ?? "No song playing")
                            .font(.subheadline).lineLimit(1)
                        Text(usesAppleMusic ? amPlayer.artist : audioManager.currentSong?.artist ?? "Now Playing")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Now Playing")
            .accessibilityValue(usesAppleMusic ? amPlayer.title : audioManager.currentSong?.title ?? "No song playing")
            .accessibilityHint("Opens playback controls")
            .accessibilityIdentifier("openNowPlaying")
            Button(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill") {
                if usesAppleMusic { Task { await amPlayer.togglePlayback() } }
                else if playing { audioManager.pause() }
                else { audioManager.play() }
            }
            .frame(minWidth: 44, minHeight: 44)
            .disabled(!usesAppleMusic && audioManager.currentSong == nil)
            Button("Next Track", systemImage: "forward.fill") {
                if usesAppleMusic { Task { await amPlayer.skip(next: true) } }
                else { audioManager.playNext() }
            }
            .frame(minWidth: 44, minHeight: 44)
            .disabled(!usesAppleMusic && audioManager.queue.isEmpty)
        }
        .accessibilityElement(children: .contain)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
