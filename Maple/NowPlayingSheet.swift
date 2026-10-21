import SwiftUI

struct NowPlayingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var amPlayer = AMPlayer.shared
    @ObservedObject private var audioManager = AudioPlayerManager.shared

    var body: some View {
        NavigationStack {
            Group {
                if amPlayer.initialized {
                    AMPlayerView2()
                } else if let song = audioManager.currentSong {
                    MediaPlayerView(song: song, allSongs: audioManager.queue)
                } else {
                    ContentUnavailableView("No song playing", systemImage: "music.note", description: Text("Choose a track from your library to start listening."))
                }
            }
            .navigationTitle("Now Playing")
            .mapleInlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(idealWidth: 520, idealHeight: 580)
    }
}
