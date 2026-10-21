import Foundation
import Combine

@MainActor
final class MusicLibraryImporter: ObservableObject {
    static let shared = MusicLibraryImporter()
    @Published private(set) var isImporting = false
    @Published var presentingImporter = false
    @Published var errorMessage: String?

    func importFiles(_ files: [URL]) {
        guard !isImporting else { return }
        isImporting = true
        Task {
            defer {
                isImporting = false
                NotificationCenter.default.post(name: MapleLibrary.changed, object: nil)
            }
            var failures: [String] = []
            for file in files {
                do {
                    let id = UUID()
                    let destination = try await Self.copyFile(file, id: id)
                    let metadata = await extractMetadata(from: destination, id: id)
                    let song = Song(id: id, title: metadata.title, artist: metadata.artist, album: metadata.album,
                                    year: metadata.year, genre: metadata.genre, duration: metadata.duration,
                                    artwork: metadata.artwork, trackNumber: metadata.trackNumber,
                                    discNumber: metadata.discNumber, ext: metadata.ext, url: destination)
                    var songs = await loadSongsFromJson()
                    songs.append(song)
                    let index = MapleLibrary.directory.appending(path: "tracks/tracks.json")
                    try JSONEncoder().encode(songs).write(to: index, options: .atomic)
                    _ = loadAlbums(song: song)
                    _ = loadArtist(song: song)
                } catch {
                    failures.append("\(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        }
    }

    nonisolated private static func copyFile(_ file: URL, id: UUID) async throws -> URL {
        let accessed = file.startAccessingSecurityScopedResource()
        defer { if accessed { file.stopAccessingSecurityScopedResource() } }
        let folder = MapleLibrary.directory.appending(path: "tracks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: id.uuidString).appendingPathExtension(file.pathExtension)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordinationError) { readableURL in
            do { try FileManager.default.copyItem(at: readableURL, to: destination) }
            catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }
        return destination
    }
}
