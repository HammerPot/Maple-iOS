import SwiftUI
import AVFoundation

struct Tracks: View {
	@State private var songs: [Song] = []
    @State private var isLoading = true
	var body: some View {
        VStack {
            if isLoading {
                ProgressView("Loading tracks...")
            } else if songs.isEmpty {
                Text("No music files found")
                    .font(.headline)
                    .foregroundColor(.gray)
                    .padding()
            } else {
                List {
                    ForEach(songs.sorted(by: { $0.title < $1.title })) { song in
                        NavigationLink(destination: AudioPlayerView(song: song, allSongs: songs.sorted(by: { $0.title < $1.title }))) {
                            Text(song.title)
                        }
                    }
                }
            }
        }
        .navigationTitle("Tracks")
        .task { await reloadLibrary() }
        .onReceive(NotificationCenter.default.publisher(for: MapleLibrary.changed)) { _ in
            Task { await reloadLibrary() }
        }
	}


    private func reloadLibrary() async {
        isLoading = true
        songs = await loadSongsFromJson()
        isLoading = false
    }

}