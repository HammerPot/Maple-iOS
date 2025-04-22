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
	var artwork: UIImage?
	var trackNumber: Int
	var discNumber: Int
}

struct Album: Identifiable {
	let id = UUID()
	let name: String
	let artist: String
	var artwork: UIImage?
	var songs: [Song]
}

struct Artist: Identifiable {
	let id = UUID()
	let name: String
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
func extractMetadata(from url: URL) async -> (title: String, artist: String, album: String, artwork: UIImage?, trackNumber: Int, discNumber: Int) {
	let asset = AVURLAsset(url: url)
	var title = url.lastPathComponent
	var artist = "Unknown Artist"
	var album = "Unknown Album"
	var artwork: UIImage? = nil
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
			case .commonKeyArtwork?:
				if let value = try await item.load(.dataValue) {
					print("artwork: \(value)")
					artwork = UIImage(data: value)
				}
			default:
				break
			}
			
			print("item: \(item.key)")
			if "\(item.key)".lowercased().contains("tpa"){
				// print("tpa: \(item.value)")
				if let value = try await item.load(.stringValue) {
						// print("value: \(value)")
						let components = value.split(separator: "/")
						if let discNum = Int(components[0]) {
							discNumber = discNum
						}
				}
			}
			if "\(item.key)".lowercased().contains("trk"){
				// print("trk: \(item.value)")
					if let value = try await item.load(.stringValue) {
						// print("tpa: \(value)")
						// Disc numbers might be in format "1/2" or just "1"
						let components = value.split(separator: "/")
						if let trackNum = Int(components[0]) {
							trackNumber = trackNum
						}
					}
			}
			// Check for track number using string identifiers
			if let identifier = item.identifier?.rawValue {
				let identifierString = identifier.lowercased()
				// print("Identifier: \(identifierString)")
				if identifierString.contains("track") || identifierString.contains("trck"){
					if let value = try await item.load(.stringValue) {
						// print("value: \(value)")
						// Track numbers might be in format "1/10" or just "1"
						let components = value.split(separator: "/")
						if let trackNum = Int(components[0]) {
							trackNumber = trackNum
						}
					}
				}
				if identifierString.contains("trkn") {
						if let value = try await item.load(.dataValue) {
							// print("track: \(value)")
						// Track numbers might be in format "1/10" or just "1"
						let bytes = [UInt8](value)
						for byte in bytes {
							// print("\(title): Num: \(byte)")
						}
						let trackNum = ((Int)(bytes[2]) << 8) | (Int)(bytes[3])
						// print("Track Number: \(trackNum)")
						trackNumber = trackNum
					}
				}
				
				// Check for disc number using string identifiers
				// if identifierString.contains("tpa") {
				// 	if let value = try await item.load(.stringValue) {
				// 		print("tpa: \(value)")
				// 		// Disc numbers might be in format "1/2" or just "1"
				// 		let components = value.split(separator: "/")
				// 		if let discNum = Int(components[0]) {
				// 			discNumber = discNum
				// 		}
				// 	}
				// }


				if identifierString.contains("disk") {
					if let value = try await item.load(.dataValue) {
						// print("disk: \(value)")
						let bytes = [UInt8](value)
						for byte in bytes {
							// print("\(title): Byte: \(byte)")
						}
						let discNum = ((Int)(bytes[2]) << 8) | (Int)(bytes[3])
						// print("Disc Number: \(discNum)")
						discNumber = discNum
					}
				}
			}
		}
	} catch {
		print("Error loading metadata for \(url.lastPathComponent): \(error.localizedDescription)")
	}
	
	return (title, artist, album, artwork, trackNumber, discNumber)
}

// Global function to load songs with metadata
func loadSongs(from urls: [URL]) async -> [Song] {
	var songs: [Song] = []
	
	for url in urls {
		let metadata = await extractMetadata(from: url)
		var song = Song(url: url, 
						title: metadata.title, 
						artist: metadata.artist, 
						album: metadata.album,
						artwork: metadata.artwork,
						trackNumber: metadata.trackNumber,
						discNumber: metadata.discNumber)
		if song.artwork == nil {
			song.artwork = UIImage(named: "Maple")
		}
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
			if album.artwork == nil {
				album.artwork = song.artwork
			}
			albumDict[albumKey] = album
		} else {
			let newAlbum = Album(name: song.album, artist: song.artist, artwork: song.artwork, songs: [song])
			albumDict[albumKey] = newAlbum
		}
	}
	
	return Array(albumDict.values).sorted { $0.name < $1.name }
}

func groupSongsByArtist(_ songs: [Song]) -> [Artist] {
	var artistDict: [String: Artist] = [:]
	for song in songs {
		let artistKey = song.artist
		if var artist = artistDict[artistKey] {
			artist.songs.append(song)
			artistDict[artistKey] = artist
		} else {
			let newArtist = Artist(name: song.artist, songs: [song])
			artistDict[artistKey] = newArtist
		}
	}
	return Array(artistDict.values).sorted { $0.name < $1.name }
}

struct Home: View {
	@State private var localFiles: [URL] = []
	var body: some View {
	   NavigationStack {
		   List {
			   NavigationLink("Tracks", value: "Tracks")
			   NavigationLink("Playlists", value: "Playlists")
			   NavigationLink("Albums", value: "Albums")
			   NavigationLink("Artists", value: "Artists")
		   }
		   .navigationTitle("Home")
		   .navigationDestination(for: String.self) { content in
				switch content {
				case "Tracks":
					Tracks(localFiles: $localFiles)
				case "Playlists":
					Text("Playlists View")
				case "Albums":
					Albums(localFiles: $localFiles)
				case "Artists":
					Artists(localFiles: $localFiles)
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





#Preview {
	Home()
}
