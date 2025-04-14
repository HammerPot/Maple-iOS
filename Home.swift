//
//  Home.swift
//  Maple
//
//  Created by Potter on 3/23/25.
//

import SwiftUI
import AVFoundation

// Models for songs and albums
struct Song: Identifiable {
	let id = UUID()
	let url: URL
	var title: String
	var artist: String
	var album: String
	var trackNumber: Int
	var discNumber: Int
}

struct Album: Identifiable {
	let id = UUID()
	let name: String
	let artist: String
	var songs: [Song]
}

// Global function to load local music files
func loadLocalFiles() -> [URL] {
	let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
	do {
		let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsDirectory,
																includingPropertiesForKeys: [.fileSizeKey])
		let musicFiles = fileURLs.filter { $0.pathExtension.lowercased() == "mp3" || 
										$0.pathExtension.lowercased() == "m4a" ||
										$0.pathExtension.lowercased() == "wav" }
		print("Found \(musicFiles.count) music files")
		return musicFiles
	} catch {
		print("Error loading local files: \(error.localizedDescription)")
		return []
	}
}

// Global function to extract metadata from audio files
func extractMetadata(from url: URL) async -> (title: String, artist: String, album: String, trackNumber: Int, discNumber: Int) {
	let asset = AVURLAsset(url: url)
	var title = url.lastPathComponent
	var artist = "Unknown Artist"
	var album = "Unknown Album"
	var trackNumber = 0
	var discNumber = 0
	
	do {
		let metadata = try await asset.load(.metadata)
		print("Metadata for \(url.lastPathComponent):")
		print(metadata)
		print("\n")
		
		for item in metadata {
			// // Print the identifier to help debug
			// print("Item identifier: \(item.identifier) | Item commonkey: \(item.commonKey) | Item KEY: \(item.key)")
			// // print("Item commonkey: \(item.commonKey)")
			// // print("Item KEY: \(item.key)")
			// if ("\(item.key)".contains("1953655662")) {
			// 	print("BLOH")
				
			// }
			switch item.commonKey {
			case .commonKeyTitle?:
				if let value = try await item.load(.stringValue) {
					title = value
				}
			case .commonKeyArtist?:
				if let value = try await item.load(.stringValue) {
					artist = value
				}
			case .commonKeyAlbumName?:
				if let value = try await item.load(.stringValue) {
					album = value
				}
			default:
				break
			}
			
			// Check for track number using string identifiers
			if let identifier = item.identifier?.rawValue {
				let identifierString = identifier.lowercased()
				print("Identifier: \(identifierString)")
				if identifierString.contains("trkn") {
					print("BLAH")
					if let value = try await item.load(.stringValue) {
						print("Value: \(value)")
					}
				}
				if identifierString.contains("track") || identifierString.contains("trck"){
					if let value = try await item.load(.stringValue) {
						// Track numbers might be in format "1/10" or just "1"
						let components = value.split(separator: "/")
						if let trackNum = Int(components[0]) {
							trackNumber = trackNum
						}
					}
				}
				if identifierString.contains("trkn") {
						if let value = try await item.load(.dataValue) {
						// Track numbers might be in format "1/10" or just "1"
						let bytes = [UInt8](value)
						let trackNum = ((Int)(bytes[2]) << 8) | (Int)(bytes[3])
						print("Track Number: \(trackNum)")
						trackNumber = trackNum
					}
				}
				
				// Check for disc number using string identifiers
				if identifierString.contains("disc") || identifierString.contains("disk") || identifierString.contains("part") || identifierString.contains("set") {
					if let value = try await item.load(.stringValue) {
						// Disc numbers might be in format "1/2" or just "1"
						let components = value.split(separator: "/")
						if let discNum = Int(components[0]) {
							discNumber = discNum
						}
					}
				}
			}
		}
	} catch {
		print("Error loading metadata for \(url.lastPathComponent): \(error.localizedDescription)")
	}
	
	return (title, artist, album, trackNumber, discNumber)
}

// Global function to load songs with metadata
func loadSongs(from urls: [URL]) async -> [Song] {
	var songs: [Song] = []
	
	for url in urls {
		let metadata = await extractMetadata(from: url)
		let song = Song(url: url, 
						title: metadata.title, 
						artist: metadata.artist, 
						album: metadata.album,
						trackNumber: metadata.trackNumber,
						discNumber: metadata.discNumber)
		songs.append(song)
	}
	
	return songs
}

// Global function to group songs by album
func groupSongsByAlbum(_ songs: [Song]) -> [Album] {
	var albumDict: [String: Album] = [:]
	
	for song in songs {
		let albumKey = "\(song.album) - \(song.artist)"
		
		if var album = albumDict[albumKey] {
			album.songs.append(song)
			albumDict[albumKey] = album
		} else {
			let newAlbum = Album(name: song.album, artist: song.artist, songs: [song])
			albumDict[albumKey] = newAlbum
		}
	}
	
	return Array(albumDict.values).sorted { $0.name < $1.name }
}

struct Home: View {
	@State private var localFiles: [URL] = []
	var body: some View {
	   NavigationStack {
			// Content()
		   List {
			   NavigationLink("Tracks", value: "Tracks")
			   NavigationLink("Playlists", value: "Playlists")
			   NavigationLink("Albums", value: "Albums")
			   NavigationLink("Artists", value: "Artists")
		   }
		   .navigationTitle("Home")
		   .navigationDestination(for: String.self) { content in
			//    Content()
				switch content {
				case "Tracks":
					TrackView(localFiles: $localFiles)
				case "Playlists":
					Text("Playlists View")
				case "Albums":
					AlbumView(localFiles: $localFiles)
				case "Artists":
					Text("Artists View")
				default:
					Text("Invalid content")
				}
			}
		}
		.onAppear {
			localFiles = loadLocalFiles()
		}
	}
}

struct TrackView: View {
	@Binding var localFiles: [URL]
	var body: some View {
		VStack {
			// MusicButton()
			
			if localFiles.isEmpty {
				Text("No music files found")
					.font(.headline)
					.foregroundColor(.gray)
					.padding()
			} else {
				List {
					ForEach(localFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }), id: \.self) { file in
						VStack(alignment: .leading) {
							Text(file.lastPathComponent)
						}
					}
				}
			}
		}
		.onAppear {
			localFiles = loadLocalFiles()
		}
	}
}

struct AlbumView: View {
	@Binding var localFiles: [URL]
	@State private var albums: [Album] = []
	@State private var isLoading = true
	
	var body: some View {
		VStack {
			if isLoading {
				ProgressView("Loading albums...")
			} else if albums.isEmpty {
				Text("No albums found")
					.font(.headline)
					.foregroundColor(.gray)
					.padding()
			} else {
				List {
					ForEach(albums) { album in
						Section(header: Text(album.name).font(.headline)) {
							Text("Artist: \(album.artist)")
								.font(.subheadline)
								.foregroundColor(.secondary)
							
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
									
									// if song.discNumber > 1 {
										Text("(Disc \(song.discNumber))")
											.font(.caption)
											.foregroundColor(.secondary)
									// }
								}
							}
						}
					}
				}
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

#Preview {
	Home()
}
