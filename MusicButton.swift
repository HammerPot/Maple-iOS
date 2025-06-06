//
//  MusicButton.swift
//  Maple
//
//  Created by Potter on 3/26/25.
//

import SwiftUI
import MusicKit
import AVFoundation

struct MusicButton: View {
	@State private var importing = false
	// @State public var songs = [AVAsset]()
	@State private var localFiles: [URL] = []
	
	var body: some View {
		VStack {
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
						// Start accessing the security-scoped resource
						guard file.startAccessingSecurityScopedResource() else {
							print("Failed to access the file")
							continue
						}
						
						// Create a local copy in the app's documents directory
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
							// Remove existing file if it exists
							if FileManager.default.fileExists(atPath: destinationURL.path) {
								print("EXTREME EDGE CASE: File already exists with the same UUID, this should never happen. File is being removed and replaced.")
								try FileManager.default.removeItem(at: destinationURL)
							}
							
							// Copy the file
							try FileManager.default.copyItem(at: file, to: destinationURL)

							Task {
								// print("Le Task")
								do {
									// print("Le Do")
									let metadata = await extractMetadata(from: destinationURL)
									// print("metaMom: \(metadata)")
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
										// print("jData: \(String(data: _jsonData, encoding: .utf8))")
										try _jsonData.write(to: jsonURL)
									}
									else {
										let jsonData = try Data(contentsOf: jsonURL)
										var songs:[Song] = try jsonDecoder.decode([Song].self, from: jsonData)
										songs.append(song)
										let _jsonData = try jsonEncoder.encode(songs)
										// print("jData: \(String(data: _jsonData, encoding: .utf8))")
										try _jsonData.write(to: jsonURL)
									}
									await loadAlbums(song: song)
								}
							}

							
							
							// Create asset from the local copy
							let asset = AVURLAsset(url: destinationURL)
							
							// Load metadata asynchronously
							// Task {
								// do {
								// 	let metadata = try await asset.load(.metadata)
									
								// 	// Extract metadata
								// 	var title = ""
								// 	var artist = ""
								// 	var album = ""
									
								// 	for item in metadata {
								// 		switch item.commonKey {
								// 		case .commonKeyTitle?:
								// 			title = try await item.load(.stringValue) ?? "Unknown Title"
								// 		case .commonKeyArtist?:
								// 			artist = try await item.load(.stringValue) ?? "Unknown Artist" 
								// 		case .commonKeyAlbumName?:
								// 			album = try await item.load(.stringValue) ?? "Unknown Album"
								// 		default:
								// 			break
								// 		}
								// 	}
									
								// 	print("Added song: \(title) by \(artist) from \(album)")
								// 	// songs.append(asset)
								// } catch {
								// 	print("Error loading metadata: \(error.localizedDescription)")
								// }
							// }
						} catch {
							print("Error copying file: \(error.localizedDescription)")
						}
						
						// Stop accessing the security-scoped resource
						file.stopAccessingSecurityScopedResource()
					}
					// Refresh local files list after importing
					loadLocalFiles()
					
				case .failure(let error):
					print("Error importing files: \(error.localizedDescription)")
				}
				importing = false
			}
			
			// //Display local files
			// List {
			// 	Section(header: Text("Locally Saved Files")) {
			// 		ForEach(localFiles, id: \.self) { file in
			// 			VStack(alignment: .leading) {
			// 				Text(file.lastPathComponent)
			// 					.font(.headline)
			// 				Text("Size: \(formatFileSize(file: file))")
			// 					.font(.caption)
			// 					.foregroundColor(.gray)
			// 			}
			// 		}
			// 	}
			// }
		Button("Clear Documents Directory") {
			clearDocumentsDirectory()
		}
		}
		.onAppear {
			loadLocalFiles()
		}
	}
	// private func loadLocalFiles() {
	// 	let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
	// 	do {
	// 		let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsDirectory,
	// 																includingPropertiesForKeys: [.fileSizeKey])
	// 		localFiles = fileURLs.filter { $0.pathExtension.lowercased() == "mp3" || 
	// 									$0.pathExtension.lowercased() == "m4a" ||
	// 									$0.pathExtension.lowercased() == "wav" }
	// 	} catch {
	// 		print("Error loading local files: \(error.localizedDescription)")
	// 	}
	// }
	
	private func clearDocumentsDirectory() {
		let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
		do {
			let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsDirectory,
																	includingPropertiesForKeys: nil)
			for fileURL in fileURLs {
				try FileManager.default.removeItem(at: fileURL)
			}
			// Refresh the local files list after clearing
			localFiles = []
		} catch {
			print("Error clearing documents directory: \(error.localizedDescription)")
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

//     func requestMusicAuthorization() async {
//         let status = await MusicAuthorization.request()
		
//         switch status {
//         case .authorized:
//             print("Access granted to Apple Music")
//         case .denied:
//             print("Access denied")
//         case .restricted:
//             print("Access restricted")
//         case .notDetermined:
//             print("Authorization not determined")
//         @unknown default:
//             print("Unknown authorization status")
//         }
//     }
// }

#Preview {
	MusicButton()
}
