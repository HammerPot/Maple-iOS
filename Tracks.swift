import SwiftUI
import AVFoundation

struct Tracks: View {
	@Binding var localFiles: [URL]
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
                Text("Tracks")
                    .font(.title)
                    .bold()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                
                List {
                    ForEach(songs.sorted(by: { $0.title < $1.title })) { song in
                        NavigationLink(destination: AudioPlayerView(song: song, allSongs: songs.sorted(by: { $0.title < $1.title }))) {
                            Text(song.title)
                        }
                    }
                }
            }
        }
		.onAppear {
			localFiles = loadLocalFiles()
			loadSongsLocal()
		}
	}


    private func loadSongsLocal() {
		isLoading = true
		print("Loading songs local")
		Task {
			let songsList = await loadSongs(from: localFiles)
			print("Songs loaded: \(songsList.count)")
			
			await MainActor.run {
				songs = songsList
				isLoading = false
                print("isloading: \(isLoading)")
			}
		}
	}
}