import SwiftUI
import AVFoundation

struct Tracks: View {
	@Binding var localFiles: [URL]
	@State private var songs: [Song] = []
    @State private var isLoading = true
	var body: some View {
        ScrollView {
            if isLoading {
                ProgressView("Loading tracks...")
            } else if songs.isEmpty {
            Text("No music files found")
                .font(.headline)
                .foregroundColor(.gray)
                .padding()
			} else {
				VStack {
					// MusicButton()
					
					if localFiles.isEmpty {
						Text("No music files found")
							.font(.headline)
							.foregroundColor(.gray)
							.padding()
					} else {
						VStack(alignment: .leading, spacing: 16) {
							VStack(alignment: .leading, spacing: 8) {
								Text("Tracks")
									.font(.title)
									.bold()
							}
							// Text("songs: \(songs.count)")
							// Text("songs: \(songs)")
							ForEach(songs.sorted(by: { $0.title < $1.title })) { song in
								// Text("song: \(song.title)")
								NavigationLink(destination: AudioPlayerView(song: song)) {
									HStack() {
										Text(song.title)
										Spacer()
									}
									.padding(.horizontal)
								}
							}
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