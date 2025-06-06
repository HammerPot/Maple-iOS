//
//  Home.swift
//  Maple
//
//  Created by Potter on 3/23/25.
//

import SwiftUI
import AVFoundation

// Models for songs and albums
struct Song: Identifiable, Codable {
	let id: UUID
	var title: String
	var artist: String
	var album: String
	var year: Int
	var genre: String
	let duration: Double
	var artwork: Data?
	// var artwork: URL
	var trackNumber: Int
	var discNumber: Int
	let ext: String
	let url: URL
}

struct Album: Identifiable, Codable {
	let id = UUID()
	var name: String
	var artist: String
	var year: Int
	var genre: String
	var artwork: Data?
	var tracks: [String]
	var songs: [Song]
}

struct Artist: Identifiable {
	let id = UUID()
	var name: String
	var songs: [Song]
}

// Global function to load local music files
func loadLocalFiles() -> [URL] {
	let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
	do {
		let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsDirectory.appendingPathComponent("tracks"),
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
func extractMetadata(from url: URL) async -> (title: String, artist: String, album: String, year: Int, genre: String, duration: Double, artwork: Data?, trackNumber: Int, discNumber: Int, ext: String) {
	let asset = AVURLAsset(url: url)
	var title = url.lastPathComponent
	var artist = "Unknown Artist"
	var album = "Unknown Album"
	var year = 0000
	var genre = "Unknown Genre"
	var duration: Double = 0
	var artwork: Data? = UIImage(named: "Maple")?.pngData()
	var trackNumber = 0
	var discNumber = 0
	var ext = "unknown"
	
	do {
		let metadata = try await asset.load(.metadata)
		print("Metadata for \(url.lastPathComponent):")
		// print(metadata)
		print("\n")
		
		for item in metadata {
			print("\(url.lastPathComponent): \(item)")
			// // Print the identifier to help debug
			// print("Item identifier: \(item.identifier) | Item commonkey: \(item.commonKey) | Item KEY: \(item.key)")
			// // print("Item commonkey: \(item.commonKey)")
			// // print("Item KEY: \(item.key)")
			// if ("\(item.key)".contains("1953655662")) {
			// 	print("BLOH")
				
			// }
			print("comm: \(item.commonKey)")
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
					artwork = value
				}
			case .commonKeyType?:
				if let value = try await item.load(.stringValue) {
					genre = value
				}
			default:
				break
			}
			
			print("item: \(item.key)")
			let identifierKey = "\(item.key)".lowercased()

			if identifierKey.contains("tpa"){
				// print("tpa: \(item.value)")
				if let value = try await item.load(.stringValue) {
						// print("value: \(value)")
						let components = value.split(separator: "/")
						if let discNum = Int(components[0]) {
							discNumber = discNum
						}
				}
			}
			if identifierKey.contains("trk"){
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
			if identifierKey.contains("tye") || identifierKey.contains("tyer") {
					// print("HIT!")
					if let value = try await item.load(.stringValue) {
						if let _year = Int(value) {
							year = _year
						}
					}
				}

			// Check for track number using string identifiers
			if let identifier = item.identifier?.rawValue {
				let identifierString = identifier.lowercased()
				print("idntStr: \(identifierString)")
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


				if identifierString.contains("day") {
					if let value = try await item.load(.stringValue) {
						if let _year = Int(value) {
							year = _year
						}
					}
				}
				if identifierString.contains("gen") {
					if let value = try await item.load(.stringValue) { 
						genre = value
					}
				}

				

			}
			print("\n")
		}
	} catch {
		print("Error loading metadata for \(url.lastPathComponent): \(error.localizedDescription)")
	}
	do {
		let durPlayer = try AVAudioPlayer(contentsOf: url)
			duration = durPlayer.duration ?? 0
			durPlayer.stop()
		
	} catch {
		print("Error in the audio player for duration calculation: \(error)")
	}
	ext = url.pathExtension
	print("item \(url.lastPathComponent)\ntitle: \("title"), artist: \(artist), album: \(album), year: \(year), genre: \(genre), duration: \(duration), artwork: \(artwork), trackNumber: \(trackNumber), discNumber: \(discNumber), ext: \(ext)\n")
	return (title, artist, album, year, genre, duration, artwork, trackNumber, discNumber, ext)
}

// Global function to load songs with metadata
func loadSongs(from urls: [URL]) async -> [Song] {
	var songs: [Song] = []
	
	for url in urls {
		let metadata = await extractMetadata(from: url)
		var song = Song(id: UUID(),
						title: metadata.title, 
						artist: metadata.artist, 
						album: metadata.album,
						year: metadata.year,
						genre: metadata.genre,
						duration: metadata.duration,
						artwork: metadata.artwork,
						trackNumber: metadata.trackNumber,
						discNumber: metadata.discNumber,
						ext: metadata.ext,
						url: url)
		if song.artwork == nil {
			song.artwork = UIImage(named: "Maple")?.pngData()
		}
		print(song)
		songs.append(song)
	}
	let jsonEncoder = JSONEncoder()
	do{
		let jsonData = try jsonEncoder.encode(songs)
		let jsonString = String(data: jsonData, encoding: .utf8)

		let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
		let songFolder = documentsDirectory.appendingPathComponent("tracks")
		let jsonURL = songFolder.appendingPathComponent("tracks.json")
		try jsonData.write(to: jsonURL)
		// print("Json data: \n\(jsonData)")
		// print("Json string: \n\(jsonString)")
	} catch {
		print("Json moment: \(error)")
	}
	return songs
}



func loadSongsFromJson() async -> [Song] {
	let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
	let songFolder = documentsDirectory.appendingPathComponent("tracks")
	let jsonURL = songFolder.appendingPathComponent("tracks.json")
	do {
		let jsonDecoder = JSONDecoder()

		if FileManager.default.fileExists(atPath: jsonURL.path) {
			let jsonData = try Data(contentsOf: jsonURL)
			let songs = try jsonDecoder.decode([Song].self, from: jsonData)
			return songs
		}
	} catch {
		print("Error loading songs from JSON: \(error)")
		return []
	}

	return []
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
			let newAlbum = Album(name: song.album, artist: song.artist, year: 0000, genre: "", artwork: song.artwork, tracks: [], songs: [song])
			albumDict[albumKey] = newAlbum
		}
	}
	
	return Array(albumDict.values).sorted { $0.name < $1.name }
}


func loadAlbumsFromJson() async -> [Album]  {
	let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
	let albumFolder = documentsDirectory.appendingPathComponent("albums")
	let jsonURL = albumFolder.appendingPathComponent("albums.json")
	do {
		let jsonDecoder = JSONDecoder()

		if FileManager.default.fileExists(atPath: jsonURL.path) {
			let jsonData = try Data(contentsOf: jsonURL)
			let albums = try jsonDecoder.decode([Album].self, from: jsonData)
			return albums.sorted { $0.name < $1.name }
		}
	} catch {
		print("Error loading songs from JSON: \(error)")
		return []
	}

	return []
}

func loadAlbums(song: Song) async -> [Album] {
	let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
	let albumsFolder = documentsDirectory.appendingPathComponent("albums")
	do {
		if !FileManager.default.fileExists(atPath: albumsFolder.path) {
			try FileManager.default.createDirectory(at: albumsFolder, withIntermediateDirectories: true, attributes: nil)
		}
	} catch {
		print("Error creating song folder: \(error.localizedDescription)")
	}
	let jsonURL = albumsFolder.appendingPathComponent("albums.json")
	var didWrite = false
	do {
		let jsonData = try Data(contentsOf: jsonURL)
		let jsonDecoder = JSONDecoder()
		let jsonEncoder = JSONEncoder()
		var albums: [Album] = try jsonDecoder.decode([Album].self, from: jsonData) 
		if albums.count > 0 {
			for (index, album) in albums.enumerated() {
				if song.album == album.name {
					albums[index].tracks.append(song.url.lastPathComponent)
					albums[index].songs.append(song)
					didWrite = true
					let albumData = try jsonEncoder.encode(albums)
					try albumData.write(to: jsonURL)
					return albums.sorted { $0.name < $1.name }
					// return
				}
			}
			if !didWrite {
				var newAlbum = Album(name: song.album, artist: song.artist, year: song.year, genre: song.genre, artwork: song.artwork, tracks: [], songs: [])
				newAlbum.tracks.append(song.url.lastPathComponent)
				newAlbum.songs.append(song)
				albums.append(newAlbum)
				didWrite = true
				let albumData = try jsonEncoder.encode(albums)
				try albumData.write(to: jsonURL)
				return albums.sorted { $0.name < $1.name }
				// return
			}
		}
		else {
			var newAlbum = Album(name: song.album, artist: song.artist, year: song.year, genre: song.genre, artwork: song.artwork, tracks: [], songs: [])
			newAlbum.tracks.append(song.url.lastPathComponent)
			newAlbum.songs.append(song)
			albums.append(newAlbum)
			didWrite = true
			let albumData = try jsonEncoder.encode(albums)
			try albumData.write(to: jsonURL)
			return albums.sorted { $0.name < $1.name }
			// return
		}
	} catch {
		print("Error loading albums from JSON: \(error)")
		return []
		// return
	}
	return []
	// return
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
