import SwiftUI
import AVFoundation

struct Albums: View {
	@Binding var localFiles: [URL]
	@State private var albums: [Album] = []
	@State private var isLoading = true
	
	private let columns = [
		GridItem(.adaptive(minimum: 160), spacing: 16)
	]
	
	var body: some View {
		ScrollView {
			if isLoading {
				ProgressView("Loading albums...")
					.padding()
			} else if albums.isEmpty {
				Text("No albums found")
					.font(.headline)
					.foregroundColor(.gray)
					.padding()
			} else {
				LazyVGrid(columns: columns, spacing: 16) {
					ForEach(albums) { album in
						NavigationLink(destination: AlbumDetailView(album: album)) {
							VStack(alignment: .leading) {
								if let artwork = album.artwork {
									Image(uiImage: artwork)
										.resizable()
										.aspectRatio(contentMode: .fill)
										.frame(width: 160, height: 160)
										.cornerRadius(8)
								} else {
									Rectangle()
										.fill(Color.gray.opacity(0.2))
										.frame(width: 160, height: 160)
										.cornerRadius(8)
										.overlay(
											Image(systemName: "music.note")
												.font(.system(size: 40))
												.foregroundColor(.gray)
										)
								}
								
								Text(album.name)
									.font(.headline)
									.lineLimit(1)
								
								Text(album.artist)
									.font(.subheadline)
									.foregroundColor(.secondary)
									.lineLimit(1)
								
								Text("\(album.songs.count) tracks")
									.font(.caption)
									.foregroundColor(.secondary)
							}
							.frame(width: 160)
						}
					}
				}
				.padding()
			}
		}
		.onAppear {
			localFiles = loadLocalFiles()
			loadAlbums()
		}
	}
	
	private func loadAlbums() {
		isLoading = true
		
		Task {
			let songs = await loadSongs(from: localFiles)
			let groupedAlbums = groupSongsByAlbum(songs)
			
			await MainActor.run {
				albums = groupedAlbums
				isLoading = false
			}
		}
	}
}