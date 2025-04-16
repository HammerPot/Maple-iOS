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

struct AlbumDetailView: View {
	let album: Album
	
	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 16) {
				if let artwork = album.artwork {
					Image(uiImage: artwork)
						.resizable()
						.aspectRatio(contentMode: .fit)
						.frame(maxWidth: .infinity)
						.cornerRadius(8)
				}
				
				VStack(alignment: .leading, spacing: 8) {
					Text(album.name)
						.font(.title)
						.bold()
					
					Text(album.artist)
						.font(.title2)
						.foregroundColor(.secondary)
				}
				.padding(.horizontal)
				
				ForEach(album.songs.sorted(by: { 
					if $0.discNumber != $1.discNumber {
						return $0.discNumber < $1.discNumber
					} else {
						return $0.trackNumber < $1.trackNumber
					}
				})) { song in
					HStack {
						Text("\(song.trackNumber).")
							.font(.caption)
							.foregroundColor(.secondary)
							.frame(width: 25, alignment: .trailing)
						
						Text(song.title)
							.font(.body)
						
						Spacer()
						
						Text("(Disc \(song.discNumber))")
							.font(.caption)
							.foregroundColor(.secondary)
					}
					.padding(.horizontal)
				}
			}
		}
		.navigationBarTitleDisplayMode(.inline)
	}
}