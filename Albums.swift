import SwiftUI
import AVFoundation

struct Albums: View {
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
									let artworkPath = MapleLibrary.directory.appendingPathComponent(artwork)
									if let uiImage = PlatformImage(contentsOfFile: artworkPath.path){
										Image(platformImage: uiImage)
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
				.padding()
			}
		}
		.navigationTitle("Albums")
        .task { await reloadLibrary() }
        .onReceive(NotificationCenter.default.publisher(for: MapleLibrary.changed)) { _ in
            Task { await reloadLibrary() }
        }
	}

    private func reloadLibrary() async {
        isLoading = true
        albums = await loadAlbumsFromJson()
        isLoading = false
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
								let artworkPath = MapleLibrary.directory.appendingPathComponent(artwork)
								if let uiImage = PlatformImage(contentsOfFile: artworkPath.path){
									Image(platformImage: uiImage)
										.resizable()
										.aspectRatio(contentMode: .fit)
										.frame(maxWidth: 320, maxHeight: 320)
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