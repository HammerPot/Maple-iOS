import SwiftUI
import AVFoundation


struct Artists: View {
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
		.navigationTitle("Artists")
		.onAppear {
			loadArtistsJ()
		}
	}

	private func loadArtistsJ() {
		isLoading = true 
		Task {
			artists = await loadArtistsFromJson()
		}
		isLoading = false
	}

	private func loadArtists() {
		isLoading = true
		
		Task {
			let songs = await loadSongsFromJson()
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
    var sortedSongs: [Song] {
        artist.songs.sorted(by: { $0.title < $1.title })
    }
	var body: some View {
		VStack {
			List {
				ForEach(sortedSongs) { song in
					NavigationLink(destination: AudioPlayerView(song: song, allSongs: sortedSongs)) {
						Text(song.title)
							.font(.body)
					}
				}
			}
		}
		.navigationTitle(artist.name)
	}
}