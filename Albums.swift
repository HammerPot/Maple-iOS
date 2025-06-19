import SwiftUI
import AVFoundation

struct Albums: View {
	// @Binding var localFiles: [URL]
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
									let artworkPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(artwork)
                					if let uiImage = UIImage(contentsOfFile: artworkPath.path){
										Image(uiImage: uiImage)
											.resizable()
											.aspectRatio(contentMode: .fill)
											.frame(width: 160, height: 160)
											.cornerRadius(8)
									}
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
									.foregroundColor(.primary)
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
				// }
				.padding()
			}
		}
		.navigationTitle("Albums")
		.onAppear {
			// localFiles = loadLocalFiles()
			loadAlbumsJ()
		}
	}
	
	private func loadAlbumsJ() {
		isLoading = true 
		Task {
			albums = await loadAlbumsFromJson()
		}
		isLoading = false
	}



	private func loadAlbums() {
		isLoading = true
		
		Task {
			let songs = await loadSongsFromJson()
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
	
	var sortedSongs: [Song] {
		album.songs.sorted(by: { 
			if $0.discNumber != $1.discNumber {
				return $0.discNumber < $1.discNumber
			} else {
				return $0.trackNumber < $1.trackNumber
			}
		})
	}
	
	var body: some View {
		VStack {
			
			List {
				Section{
				// VStack(alignment: .leading, spacing: 8) {
				// 	if let artwork = album.artwork {
				// 		let artworkPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(artwork)
				// 		if let uiImage = UIImage(contentsOfFile: artworkPath.path){
				// 			Image(uiImage: uiImage)
				// 				.resizable()
				// 				.aspectRatio(contentMode: .fit)
				// 				.frame(maxWidth: .infinity)
				// 				.cornerRadius(8)
				// 				.padding(.horizontal)
				// 		}
				// 	}
				
				// 	Text(album.name)
				// 		.font(.title)
				// 		.bold()
					
				// 	Text(album.artist)
				// 		.font(.title2)
				// 		.foregroundColor(.secondary)
				// }
				// .frame(maxWidth: .infinity, alignment: .leading)
				// .padding(.horizontal)
					ForEach(sortedSongs) { song in
						NavigationLink(destination: AudioPlayerView(song: song, allSongs: sortedSongs)) {
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
						}
					}
				} header: {
						VStack(alignment: .leading, spacing: 8) {
							if let artwork = album.artwork {
								let artworkPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(artwork)
								if let uiImage = UIImage(contentsOfFile: artworkPath.path){
									Image(uiImage: uiImage)
										.resizable()
										.aspectRatio(contentMode: .fit)
										.frame(maxWidth: .infinity)
										.cornerRadius(8)
										.padding(.horizontal)
								}
							}
						
							Text(album.name)
								.font(.title)
								.bold()
								.foregroundColor(.primary)
								.frame(maxWidth: .infinity, alignment: .center)
							
							Text(album.artist)
								.font(.title2)
								.foregroundColor(.secondary)
								.frame(maxWidth: .infinity, alignment: .center)
						}
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(.horizontal)
				}
			} 
		}
	}
}