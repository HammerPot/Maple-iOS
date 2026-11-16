import Foundation
import OSLog

/// Serializes all catalog and media writes on its own executor.
actor LibraryDisk {
    let root: URL
    private var savedRevision: UInt64 = 0
    private let logger = Logger(subsystem: "com.maple.library", category: "Persistence")
    init(root: URL) { self.root = root }
    private var catalogURL: URL { root.appendingPathComponent("library/catalog.json") }
    private var backupURL: URL { root.appendingPathComponent("library/catalog.backup.json") }

    func load() throws -> (LibraryCatalog, String?) {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("library"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tracks"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        let exists = FileManager.default.fileExists(atPath: catalogURL.path)
        if exists {
            do { return (try decode(catalogURL), nil) }
            catch LibraryError.unsupportedVersion(let version) { throw LibraryError.unsupportedVersion(version) }
            catch {
                logger.error("Catalog could not be read: \(error.localizedDescription, privacy: .public)")
                // Keep the original for recovery. Never re-run legacy migration after a catalog existed.
                try FileManager.default.copyItem(at: catalogURL, to: root.appendingPathComponent("library/corrupt-\(UUID().uuidString).json"))
                if let backup = try? decode(backupURL) { return (backup, "Your library was recovered from its backup.") }
                return (LibraryCatalog(), "The library catalog was damaged. Scan for new files to recover your audio. The original catalog has been kept.")
            }
        }
        if FileManager.default.fileExists(atPath: backupURL.path) {
            return (try decode(backupURL), "Your library was recovered from its backup.")
        }
        let migrated = migrateLegacy()
        try save(migrated)
        return (migrated, nil)
    }
    private func decode(_ url: URL) throws -> LibraryCatalog {
        let data = try Data(contentsOf: url)
        struct Header: Decodable { let version: Int }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.version == 1 else { throw LibraryError.unsupportedVersion(header.version) }
        let result = try JSONDecoder().decode(LibraryCatalog.self, from: data)
        for track in result.tracks {
            guard !track.fileName.isEmpty, track.fileName == URL(fileURLWithPath: track.fileName).lastPathComponent else { throw LibraryError.unsafePath }
        }
        savedRevision = result.revision
        return result
    }
    func save(_ catalog: LibraryCatalog) throws {
        guard catalog.revision >= savedRevision else { return }
        let data = try JSONEncoder().encode(catalog)
        try data.write(to: catalogURL, options: .atomic)
        savedRevision = catalog.revision
        // Backup is a second independently atomic copy of the latest successful checkpoint.
        try data.write(to: backupURL, options: .atomic)
    }
    private func migrateLegacy() -> LibraryCatalog {
        var result = LibraryCatalog()
        var fileNames = Set<String>()
        var ids = Set<UUID>()
        // Album/artist snapshots can salvage tracks when tracks.json is missing or partially corrupt.
        for path in ["tracks/tracks.json", "albums/albums.json", "artists/artists.json"] {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(path)),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            let songs = path.hasPrefix("tracks/") ? rows : rows.flatMap { $0["songs"] as? [[String: Any]] ?? [] }
            for object in songs {
                guard let urlString = object["url"] as? String else { continue }
                let fileName = (URL(string: urlString) ?? URL(fileURLWithPath: urlString)).lastPathComponent
                guard !fileName.isEmpty, fileNames.insert(fileName).inserted else { continue }
                var id = (object["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
                if !ids.insert(id).inserted { id = UUID(); ids.insert(id) }
                let artwork = (object["artwork"] as? String).flatMap { reference -> String? in
                    let name = URL(fileURLWithPath: reference).lastPathComponent
                    return name.isEmpty ? nil : "images/" + name
                }
                let audio = root.appendingPathComponent("tracks").appendingPathComponent(fileName)
                let added = (try? audio.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
                result.tracks.append(LibraryTrack(id: id, fileName: fileName,
                    title: object["title"] as? String ?? "", artist: object["artist"] as? String ?? "",
                    album: object["album"] as? String ?? "", albumArtist: object["albumArtist"] as? String,
                    year: object["year"] as? Int ?? 0, genre: object["genre"] as? String ?? "",
                    duration: object["duration"] as? Double ?? 0, trackNumber: object["trackNumber"] as? Int ?? 0,
                    discNumber: object["discNumber"] as? Int ?? 0, artwork: artwork, dateAdded: added,
                    lyrics: object["lyrics"] as? String))
            }
        }
        return result
    }
    func candidates(in urls: [URL]) throws -> [URL] {
        var result: [URL] = []
        var seen = Set<URL>()
        for url in urls {
            try Task.checkCancellation()
            let folder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if folder, let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let child as URL in enumerator {
                    try Task.checkCancellation()
                    guard (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                          AudioMetadataReader.isCandidate(child), seen.insert(child.standardizedFileURL).inserted else { continue }
                    result.append(child)
                }
            } else if AudioMetadataReader.isCandidate(url), seen.insert(url.standardizedFileURL).inserted { result.append(url) }
        }
        return result.sorted { $0.path < $1.path }
    }
    func stageAudio(from source: URL, fileName: String, moving: Bool = false) throws {
        try Task.checkCancellation()
        let target = root.appendingPathComponent("tracks").appendingPathComponent(fileName)
        if moving {
            let path = source.resolvingSymlinksInPath().path
            guard path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw LibraryError.unsafePath }
            try FileManager.default.moveItem(at: source, to: target)
            return
        }
        let temporary = root.appendingPathComponent("library/\(UUID().uuidString).import")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: target)
    }
    func saveArtwork(_ data: Data) throws -> String {
        let reference = "images/\(UUID().uuidString).image"
        try data.write(to: root.appendingPathComponent(reference), options: .atomic)
        return reference
    }
    func removeLegacyCatalogs() throws {
        for path in ["tracks/tracks.json", "albums/albums.json", "artists/artists.json"] {
            let url = root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    func removeFiles(_ references: [String]) throws {
        for reference in Set(references) {
            let parts = reference.split(separator: "/")
            guard parts.count == 2, ["tracks", "images"].contains(String(parts[0])), !parts.contains("..") else { throw LibraryError.unsafePath }
            let url = root.appendingPathComponent(reference)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
}
