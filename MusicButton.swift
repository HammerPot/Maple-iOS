//
//  MusicButton.swift
//  Maple
//
//  Created by Potter on 3/26/25.
//

import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct MusicButton: View {
	@State private var importing = false
	@State private var localFiles: [URL] = []
	
	var body: some View {
			Button("Upload Music") {
				importing = true
			}
			.fileImporter(
				isPresented: $importing,
				allowedContentTypes: [.audio],
				allowsMultipleSelection: true
			) { result in
				switch result {
				case .success(let files):
					for file in files {
						guard file.startAccessingSecurityScopedResource() else {
							print("Failed to access the file")
							continue
						}
						
						let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
						print("Documents directory: \(documentsDirectory)")
						let songFolder = documentsDirectory.appendingPathComponent("tracks")
						do {
							if !FileManager.default.fileExists(atPath: songFolder.path) {
								try FileManager.default.createDirectory(at: songFolder, withIntermediateDirectories: true, attributes: nil)
							}
						} catch {
							print("Error creating song folder: \(error.localizedDescription)")
						}
						let UUID = UUID()
						let fileExt = file.pathExtension
						let fileName = UUID.uuidString + "." + fileExt
						let destinationURL = songFolder.appendingPathComponent(fileName)
						print("Destination URL: \(destinationURL)")
						
						do {
							if FileManager.default.fileExists(atPath: destinationURL.path) {
								print("EXTREME EDGE CASE: File already exists with the same UUID, this should never happen. File is being removed and replaced.")
								try FileManager.default.removeItem(at: destinationURL)
							}
							
							try FileManager.default.copyItem(at: file, to: destinationURL)

							Task {
								do {
									let metadata = await extractMetadata(from: destinationURL, id: UUID)
									var song = Song(id: UUID,
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
										url: destinationURL)

									let jsonURL = songFolder.appendingPathComponent("tracks.json")
									let jsonDecoder = JSONDecoder()
									let jsonEncoder = JSONEncoder()

									var songs: [Song] = []
									if !FileManager.default.fileExists(atPath: jsonURL.path) {
										songs.append(song)
										let _jsonData = try jsonEncoder.encode(songs)
										try _jsonData.write(to: jsonURL)
									}
									else {
										let jsonData = try Data(contentsOf: jsonURL)
										var songs:[Song] = try jsonDecoder.decode([Song].self, from: jsonData)
										songs.append(song)
										let _jsonData = try jsonEncoder.encode(songs)
										try _jsonData.write(to: jsonURL)
									}
									loadAlbums(song: song)
									loadArtist(song: song)
									print("Song \(destinationURL.lastPathComponent) has finished doing its last do-task in theory")
								}
							}
							print("Song \(destinationURL.lastPathComponent) this print should be AFTER do-task's")
							
							
						} catch {
							print("Error copying file: \(error.localizedDescription)")
						}
						
						file.stopAccessingSecurityScopedResource()
					}
					loadLocalFiles()
					
				case .failure(let error):
					print("Error importing files: \(error.localizedDescription)")
				}
				importing = false
			}
			
	}
	private func formatFileSize(file: URL) -> String {
		do {
			let resourceValues = try file.resourceValues(forKeys: [.fileSizeKey])
			let fileSize = resourceValues.fileSize ?? 0
			let byteCountFormatter = ByteCountFormatter()
			byteCountFormatter.allowedUnits = [.useMB]
			byteCountFormatter.countStyle = .file
			return byteCountFormatter.string(fromByteCount: Int64(fileSize))
		} catch {
			return "Unknown size"
		}
	}
}

func clearDocumentsDirectory() {
	let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
	do {
		let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsDirectory,
																includingPropertiesForKeys: nil)
		for fileURL in fileURLs {
			try FileManager.default.removeItem(at: fileURL)
		}
	} catch {
		print("Error clearing documents directory: \(error.localizedDescription)")
	}
}

#Preview {
	MusicButton()
}
