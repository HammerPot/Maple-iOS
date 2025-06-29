//
//  Home.swift
//  Maple
//
//  Created by Potter on 3/23/25.
//

import SwiftUI
import AVFoundation

struct Song: Identifiable, Codable {
	let id: UUID
	var title: String
	var artist: String
	var album: String
	var year: Int
	var genre: String
	let duration: Double
	var artwork: String?
	var trackNumber: Int
	var discNumber: Int
	let ext: String
	var url: URL
}

struct Album: Identifiable, Codable {
	let id = UUID()
	var name: String
	var artist: String
	var year: Int
	var genre: String
	var artwork: String?
	var tracks: [String]
	var songs: [Song]
}

struct Artist: Identifiable, Codable {
	let id = UUID()
	var name: String
	var tracks: [String]
	var albums: [String]
	var songs: [Song]
}

struct Playlist: Identifiable, Codable {
	let id = UUID()
	var name: String
	var description: String
	var artwork: String?
	var tracks: [String]
	var songs: [Song]
}

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

func extractMetadata(from url: URL, id: UUID) async -> (title: String, artist: String, album: String, year: Int, genre: String, duration: Double, artwork: String, trackNumber: Int, discNumber: Int, ext: String) {
	let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

	let asset = AVURLAsset(url: url)
	var title = url.lastPathComponent
	var artist = "Unknown Artist"
	var album = "Unknown Album"
	var year = 0000
	var genre = "Unknown Genre"
	var duration: Double = 0
	var artwork = ""
	var _artwork: Data? = UIImage(named: "Maple")?.pngData()
	var trackNumber = 0
	var discNumber = 0
	var ext = "unknown"
	
	do {
		let metadata = try await asset.load(.metadata)
		print("Metadata for \(url.lastPathComponent):")
		print("\n")
		
		for item in metadata {
			print("\(url.lastPathComponent): \(item)")
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
					_artwork = value
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
				if let value = try await item.load(.stringValue) {
						let components = value.split(separator: "/")
						if let discNum = Int(components[0]) {
							discNumber = discNum
						}
				}
			}
			if identifierKey.contains("trk"){
					if let value = try await item.load(.stringValue) {
						let components = value.split(separator: "/")
						if let trackNum = Int(components[0]) {
							trackNumber = trackNum
						}
					}
			}
			if identifierKey.contains("tye") || identifierKey.contains("tyer") {
					if let value = try await item.load(.stringValue) {
						if let _year = Int(value) {
							year = _year
						}
					}
				}

			if let identifier = item.identifier?.rawValue {
				let identifierString = identifier.lowercased()
				print("idntStr: \(identifierString)")
				if identifierString.contains("track") || identifierString.contains("trck"){
					if let value = try await item.load(.stringValue) {
						let components = value.split(separator: "/")
						if let trackNum = Int(components[0]) {
							trackNumber = trackNum
						}
					}
				}
				if identifierString.contains("trkn") {
						if let value = try await item.load(.dataValue) {
						let bytes = [UInt8](value)
						for byte in bytes {
						}
						let trackNum = ((Int)(bytes[2]) << 8) | (Int)(bytes[3])
						trackNumber = trackNum
					}
				}
				
				if identifierString.contains("disk") {
					if let value = try await item.load(.dataValue) {
						let bytes = [UInt8](value)
						for byte in bytes {
						}
						let discNum = ((Int)(bytes[2]) << 8) | (Int)(bytes[3])
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
	let imagePath = documentDirectory.appendingPathComponent("images")
	let artworkPath = imagePath.appendingPathComponent("\(id.uuidString).image")
	artwork = "/images/\(artworkPath.lastPathComponent)"
	do {
		if !FileManager.default.fileExists(atPath: imagePath.path){
			try FileManager.default.createDirectory(at: imagePath, withIntermediateDirectories: true, attributes: nil)
			try UIImage(named: "Maple")?.pngData()?.write(to: imagePath.appendingPathComponent("maple.image"))
		}
		try _artwork?.write(to: artworkPath)
	} catch{
		print("Error trying to save artwork: \(error)")
	}
	print("item \(url.lastPathComponent)\ntitle: \("title"), artist: \(artist), album: \(album), year: \(year), genre: \(genre), duration: \(duration), artwork: \(artwork), trackNumber: \(trackNumber), discNumber: \(discNumber), ext: \(ext)\n")
	return (title, artist, album, year, genre, duration, artwork, trackNumber, discNumber, ext)
}

func loadSongs(from urls: [URL]) async -> [Song] {
	var songs: [Song] = []
	
	for url in urls {
		let uuid = UUID()
		let metadata = await extractMetadata(from: url, id: uuid)
		var song = Song(id: uuid,
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
		print("Error loading albums from JSON: \(error)")
		return []
	}

	return []
}

func loadArtistsFromJson() async -> [Artist] {
	let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
	let artistFolder = documentsDirectory.appendingPathComponent("artists")
	let jsonURL = artistFolder.appendingPathComponent("artists.json")
	do {
		let jsonDecoder = JSONDecoder()

		if FileManager.default.fileExists(atPath: jsonURL.path) {
			let jsonData = try Data(contentsOf: jsonURL)
			let artists = try jsonDecoder.decode([Artist].self, from: jsonData)
			return artists
		}
	} catch {
		print("Error loading artists from JSON: \(error)")
		return []
	}

	return []
}

func loadArtist(song: Song) -> [Artist] {
	let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
	let artistsFolder = documentsDirectory.appendingPathComponent("artists")
	do {
		if !FileManager.default.fileExists(atPath: artistsFolder.path) {
			try FileManager.default.createDirectory(at: artistsFolder, withIntermediateDirectories: true, attributes: nil)
		}
	} catch {
		print("Error creating artist folder: \(error.localizedDescription)")
	}
	let jsonURL = artistsFolder.appendingPathComponent("artists.json")
	var didWrite = false
	do {
		let jsonDecoder = JSONDecoder()
		let jsonEncoder = JSONEncoder()
		if FileManager.default.fileExists(atPath: jsonURL.path) {
			let jsonData = try Data(contentsOf: jsonURL)
			var artists: [Artist] = try jsonDecoder.decode([Artist].self, from: jsonData) 
			for (index, artist) in artists.enumerated() {
				if song.artist == artist.name {
					let fileName = song.url.lastPathComponent
					let fileExt = song.url.pathExtension
					let pathPre = song.url.deletingPathExtension().lastPathComponent
					artists[index].tracks.append(pathPre)
					artists[index].albums.append(song.album)
					artists[index].songs.append(song)
					let artistData = try jsonEncoder.encode(artists)
					try artistData.write(to: jsonURL)
					return artists
				}
			}
			if !didWrite {
				var newArtist = Artist(name: song.artist, tracks: [], albums: [], songs: [])
				let fileName = song.url.lastPathComponent
				let fileExt = song.url.pathExtension
				let pathPre = song.url.deletingPathExtension().lastPathComponent
				newArtist.tracks.append(pathPre)
				newArtist.albums.append(song.album)
				newArtist.songs.append(song)
				artists.append(newArtist)
				let artistData = try jsonEncoder.encode(artists)
				try artistData.write(to: jsonURL)
				return artists
			}
		}
		else {
			var artists: [Artist] = []
			var newArtist = Artist(name: song.artist, tracks: [], albums: [], songs: [])
			let fileName = song.url.lastPathComponent
			let fileExt = song.url.pathExtension
			let pathPre = song.url.deletingPathExtension().lastPathComponent
			newArtist.tracks.append(pathPre)
			newArtist.albums.append(song.album)
			newArtist.songs.append(song)
			artists.append(newArtist)
			let artistData = try jsonEncoder.encode(artists)
			try artistData.write(to: jsonURL)
			return artists
		}
	} catch {
		print("Error loading/pushing artists with JSON: \(error)")
		return []
	}
	return []
}

func loadAlbums(song: Song)  -> [Album] {
	let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
	let albumsFolder = documentsDirectory.appendingPathComponent("albums")
	do {
		if !FileManager.default.fileExists(atPath: albumsFolder.path) {
			try FileManager.default.createDirectory(at: albumsFolder, withIntermediateDirectories: true, attributes: nil)
		}
	} catch {
		print("Error creating album folder: \(error.localizedDescription)")
	}
	let jsonURL = albumsFolder.appendingPathComponent("albums.json")
	var didWrite = false
	do {
		let jsonDecoder = JSONDecoder()
		let jsonEncoder = JSONEncoder()
		if FileManager.default.fileExists(atPath: jsonURL.path) {
			let jsonData = try Data(contentsOf: jsonURL)
			var albums: [Album] = try jsonDecoder.decode([Album].self, from: jsonData) 
			for (index, album) in albums.enumerated() {
				if song.album == album.name {
					let fileName = song.url.lastPathComponent
					let fileExt = song.url.pathExtension
					let pathPre = song.url.deletingPathExtension().lastPathComponent
					print("HALB: \(pathPre)")
					albums[index].tracks.append(pathPre)
					albums[index].songs.append(song)
					didWrite = true
					let albumData = try jsonEncoder.encode(albums)
					try albumData.write(to: jsonURL)
					return albums.sorted { $0.name < $1.name }
				}
			}
			if !didWrite {
				var newAlbum = Album(name: song.album, artist: song.artist, year: song.year, genre: song.genre, artwork: song.artwork, tracks: [], songs: [])
				let fileName = song.url.lastPathComponent
				let fileExt = song.url.pathExtension
				let pathPre = song.url.deletingPathExtension().lastPathComponent
				print("HALB: \(pathPre)")
				newAlbum.tracks.append(pathPre)
				newAlbum.songs.append(song)
				albums.append(newAlbum)
				didWrite = true
				let albumData = try jsonEncoder.encode(albums)
				try albumData.write(to: jsonURL)
				return albums.sorted { $0.name < $1.name }
			}
		}
		else {
			var albums: [Album] = []
			var newAlbum = Album(name: song.album, artist: song.artist, year: song.year, genre: song.genre, artwork: song.artwork, tracks: [], songs: [])
			let fileName = song.url.lastPathComponent
			let fileExt = song.url.pathExtension
			let pathPre = song.url.deletingPathExtension().lastPathComponent
			print("HALB: \(pathPre)")
			newAlbum.tracks.append(pathPre)
			newAlbum.songs.append(song)
			albums.append(newAlbum)
			didWrite = true
			let albumData = try jsonEncoder.encode(albums)
			try albumData.write(to: jsonURL)
			return albums.sorted { $0.name < $1.name }
		}
	} catch {
		print("Error loading albums from JSON: \(error)")
		return []
	}
	return []
}

func groupSongsByArtist(_ songs: [Song]) -> [Artist] {
	var artistDict: [String: Artist] = [:]
	for song in songs {
		let artistKey = song.artist
		if var artist = artistDict[artistKey] {
			artist.songs.append(song)
			artistDict[artistKey] = artist
		} else {
			let newArtist = Artist(name: song.artist, tracks: [], albums: [], songs: [song])
			artistDict[artistKey] = newArtist
		}
	}
	return Array(artistDict.values).sorted { $0.name < $1.name }
}

struct Home: View {
	@ObservedObject private var manager = AppleMusicManager.shared
	@State private var localFiles: [URL] = []
	var body: some View {
	   NavigationStack {
		   List {
				Section() {
					NavigationLink("Tracks", value: "Tracks")
					//    NavigationLink("Playlists", value: "Playlists")
					NavigationLink("Albums", value: "Albums")
					NavigationLink("Artists", value: "Artists")
				}
				if manager.authStatus == .authorized {
					Section() {
						NavigationLink("Apple Music", value: "Apple Music")
					}
				}
		   	}
		   .navigationTitle("Home")
		   .navigationDestination(for: String.self) { content in
				switch content {
				case "Tracks":
					Tracks()
				case "Playlists":
					Playlists()
				case "Albums":
					Albums()
				case "Artists":
					Artists()
				case "Apple Music":
					AppleMusic()
				default:
					Text("Invalid content")
				}
			}
		}
		.onAppear {

		}
	}
}





#Preview {
	Home()
}
