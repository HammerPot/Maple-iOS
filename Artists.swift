import SwiftUI
import AVFoundation


struct Artists: View {
	@Binding var localFiles: [URL]
	@State private var artists: [Artist] = []
	@State private var isLoading = true
	
	var body: some View {
		VStack {
			if isLoading {
				ProgressView("Loading artists...")
			} else if artists.isEmpty {
				Text("No artists found")
					.font(.headline)
					.foregroundColor(.gray)
					.padding()
			} else {
				List {
                    ForEach(artists) { artist in
                        NavigationLink(destination: ArtistDetailView(artist: artist)) {
                            Text(artist.name)
                        }
                    }
                }
            }
        }
        .onAppear {
            localFiles = loadLocalFiles()
            loadArtists()
        }

    }

    private func loadArtists() {
		isLoading = true
		
		Task {
			let songs = await loadSongs(from: localFiles)
			let groupedArtists = groupSongsByArtist(songs)
			
			await MainActor.run {
				artists = groupedArtists
				isLoading = false
			}
		}
	}
}



struct ArtistDetailView: View {
	let artist: Artist
	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 16) {
				VStack(alignment: .leading, spacing: 8) {
					Text(artist.name)
						.font(.title)
						.bold()
				}
				.padding(.horizontal)
				ForEach(artist.songs) { song in
					HStack {
					    Text(song.title)
							.font(.body)
						Spacer()
                    }
					.padding(.horizontal)
				}
			}
		}
		// .navigationBarTitleDisplayMode(.inline)
		.onAppear {
			// print("BLRH \(artist.songs)")
		}
	}
}