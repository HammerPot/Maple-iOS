import SwiftUI

struct LocalPlayerControls: View {
    @ObservedObject private var audioManager = AudioPlayerManager.shared

    private var artwork: PlatformImage? {
        guard let path = audioManager.currentSong?.artwork else { return nil }
        return PlatformImage(contentsOfFile: MapleLibrary.directory.appending(path: path).path)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Group {
                    if let artwork { Image(platformImage: artwork).resizable() }
                    else { Image("Maple").resizable() }
                }
                .scaledToFit()
                .frame(maxWidth: 240, maxHeight: 240)
                .clipShape(.rect(cornerRadius: 8))
                .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text(audioManager.currentSong?.title ?? "No song playing").font(.headline)
                    Text(audioManager.currentSong?.artist ?? "Unknown artist")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 24) {
                    Button("Previous Track", systemImage: "backward.fill") { audioManager.playPrevious() }
                    Button(audioManager.isPlaying ? "Pause" : "Play", systemImage: audioManager.isPlaying ? "pause.fill" : "play.fill") {
                        if audioManager.isPlaying { audioManager.pause() }
                        else { audioManager.play() }
                    }
                    Button("Next Track", systemImage: "forward.fill") { audioManager.playNext() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(audioManager.currentSong == nil)
                VStack {
                    Slider(value: Binding(
                        get: { min(max(audioManager.currentTime, 0), max(audioManager.duration, 1)) },
                        set: { audioManager.seek(to: $0) }
                    ), in: 0...max(audioManager.duration, 1))
                    .accessibilityLabel("Playback position")
                    .disabled(audioManager.duration <= 0)
                    HStack {
                        Text(Duration.seconds(max(audioManager.currentTime, 0)), format: .time(pattern: .minuteSecond))
                        Spacer()
                        Text(Duration.seconds(max(audioManager.duration, 0)), format: .time(pattern: .minuteSecond))
                    }.font(.caption).monospacedDigit()
                }
            }
            .padding()
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Now Playing")
        .mapleInlineTitle()
    }
}
