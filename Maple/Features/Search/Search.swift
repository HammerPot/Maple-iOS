//
//  Search.swift
//  Maple
//
//  Created by Potter on 6/8/25.
//

import SwiftUI

struct Result: Identifiable {
	let id = UUID()
	var name: String
	var type: String
	var destination: AnyView
	var song: Song? = nil
	var album: Album? = nil
	var artist: Artist? = nil
}

struct Search: View {
	@State private var searchText: String = ""
	@State private var songs: [Song] = []
	@State private var albums: [Album] = []
	@State private var artists: [Artist] = []
	@State private var sResults: [Result] = []
	@State private var alResults: [Result] = []
	@State private var arResults: [Result] = []
	@State private var results: [Result] = []

	var body: some View {
		NavigationStack {
			if filteredResults.isEmpty {
				if searchText == "" {
					Text("Search")
				}
				else {
					Text("No Results Found")
				}
			} else {
				List {
					ForEach(filteredResults) { result in
						NavigationLink(destination: result.destination) {
							HStack {
								if let art = result.song?.artwork {
									if let uiImage = UIImage(contentsOfFile: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(art).path) {
										Image(uiImage: uiImage)
											.resizable()
											.scaledToFit()
											.frame(width: 50, height: 50)
									}
								}
								else if let art = result.album?.artwork {
									if let uiImage = UIImage(contentsOfFile: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(art).path) {
										Image(uiImage: uiImage)
											.resizable()
											.scaledToFit()
											.frame(width: 50, height: 50)
									}
								}
								VStack {
									Text(result.name)
										.font(.headline)
									Text(result.type)
										.font(.subheadline)
								}
							}
						}
					}
				}
			}
		}
		.searchable(text: $searchText)
		.onAppear {
			Task{
				sResults = []
				arResults = []
				alResults = []
				results = []
				songs = await loadSongsFromJson()
				albums = await loadAlbumsFromJson()
				artists = await loadArtistsFromJson()
				
				for song in songs {
					sResults.append(Result(name: song.title, type: "song", destination: AnyView(AudioPlayerView(song: song, allSongs: [song])), song: song))
				}
				for album in albums {
					alResults.append(Result(name: album.name, type: "album", destination: AnyView(AlbumDetailView(album: album)), album: album))
				}
				for artist in artists {
					arResults.append(Result(name: artist.name, type: "artist", destination: AnyView(ArtistDetailView(artist: artist)), artist: artist))
				}
				
				results = sResults + arResults + alResults
			
			}
		}
	}
	
	var filteredResults: [Result] {
		if searchText.isEmpty {
			return []
		} else {
			return results.filter { result in 
				result.name.lowercased().contains(searchText.lowercased())
			}
		}
	}
}

#Preview {
	Search()
}
