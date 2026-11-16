import CryptoKit
import Foundation
import OSLog

/// Serializes all catalog and media writes on its own executor.
actor LibraryDisk {
    /// User-visible media root (`Documents`): `tracks/` audio and `images/` artwork.
    let root: URL
    /// Private catalog location. The app passes Application Support so the catalog never
    /// appears in the Files app next to the user's music; tests use a temporary folder.
    let catalogDirectory: URL
    private var savedRevision: UInt64 = 0
    private let logger = Logger(subsystem: "com.maple.library", category: "Persistence")
    init(root: URL, catalogDirectory: URL? = nil) {
        self.root = root
        self.catalogDirectory = catalogDirectory ?? root.appendingPathComponent("library")
    }
    private var catalogURL: URL { catalogDirectory.appendingPathComponent("catalog.json") }
    private var backupURL: URL { catalogDirectory.appendingPathComponent("catalog.backup.json") }
    /// Staging area for copies; on the same volume as `tracks/` so the final move is atomic.
    private var stagingDirectory: URL { root.appendingPathComponent("tracks/.staging") }

    func load() throws -> (LibraryCatalog, String?) {
        try FileManager.default.createDirectory(at: catalogDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tracks"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        let exists = FileManager.default.fileExists(atPath: catalogURL.path)
        if exists {
            do { return (try decode(catalogURL), nil) }
            catch LibraryError.unsupportedVersion(let version) { throw LibraryError.unsupportedVersion(version) }
            catch {
                logger.error("Catalog could not be read: \(error.localizedDescription, privacy: .public)")
                // Keep the original for recovery. Never re-run legacy migration after a catalog existed.
                try FileManager.default.copyItem(at: catalogURL, to: catalogDirectory.appendingPathComponent("corrupt-\(UUID().uuidString).json"))
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
    /// One-shot import of the pre-5.0 JSON files. Runs only when no catalog (or backup) exists,
    /// and the result is saved immediately, so it can never run twice. Audio is left in place.
    private func migrateLegacy() -> LibraryCatalog {
        var result = LibraryCatalog()
        var fileNames = Set<String>()
        var ids = Set<UUID>()
        var missingAudio = 0
        let fileManager = FileManager.default
        // Album/artist snapshots embed full song copies, so they can salvage tracks when
        // tracks.json is missing or corrupt. tracks.json is read first and wins.
        for path in ["tracks/tracks.json", "albums/albums.json", "artists/artists.json"] {
            let url = root.appendingPathComponent(path)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            guard let data = try? Data(contentsOf: url),
                  let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                logger.error("Legacy \(path, privacy: .public) is unreadable; skipping it")
                continue
            }
            let songs = path.hasPrefix("tracks/") ? rows : rows.flatMap { $0["songs"] as? [[String: Any]] ?? [] }
            for object in songs {
                // `url` was an absolute path inside a container that changes between installs;
                // only its last path component is trustworthy.
                // JSONEncoder writes URL as a string; other encoders use {"relative": …}.
                guard let urlString = object["url"] as? String ?? (object["url"] as? [String: Any])?["relative"] as? String else { continue }
                let fileName = (URL(string: urlString) ?? URL(fileURLWithPath: urlString)).lastPathComponent
                guard !fileName.isEmpty, fileName != "/", !fileNames.contains(fileName) else { continue }
                let audio = root.appendingPathComponent("tracks").appendingPathComponent(fileName)
                guard fileManager.fileExists(atPath: audio.path) else { missingAudio += 1; continue }
                fileNames.insert(fileName)
                var id = (object["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
                if !ids.insert(id).inserted { id = UUID(); ids.insert(id) }
                // Legacy artwork is "/images/<uuid>.image", relative to Documents.
                let artwork = (object["artwork"] as? String).flatMap { reference -> String? in
                    let name = URL(fileURLWithPath: reference).lastPathComponent
                    guard !name.isEmpty, name != "/" else { return nil }
                    return fileManager.fileExists(atPath: root.appendingPathComponent("images").appendingPathComponent(name).path) ? "images/" + name : nil
                }
                let added = (try? audio.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
                result.tracks.append(LibraryTrack(id: id, fileName: fileName,
                    title: object["title"] as? String ?? "", artist: object["artist"] as? String ?? "",
                    album: object["album"] as? String ?? "", albumArtist: object["albumArtist"] as? String,
                    year: (object["year"] as? NSNumber)?.intValue ?? 0, genre: object["genre"] as? String ?? "",
                    duration: (object["duration"] as? NSNumber)?.doubleValue ?? 0,
                    trackNumber: (object["trackNumber"] as? NSNumber)?.intValue ?? 0,
                    discNumber: (object["discNumber"] as? NSNumber)?.intValue ?? 0, artwork: artwork, dateAdded: added,
                    lyrics: object["lyrics"] as? String))
            }
        }
        if !result.tracks.isEmpty || missingAudio > 0 {
            logger.notice("Migrated \(result.tracks.count) legacy tracks; \(missingAudio) entries had no audio file and were dropped")
        }
        return result
    }
    /// Expands folders recursively. Files the user picked explicitly that are clearly not audio
    /// are returned as `rejected` so the summary can say so instead of silently ignoring them.
    func candidates(in urls: [URL]) throws -> (files: [URL], rejected: [String]) {
        var result: [URL] = []
        var rejected: [String] = []
        var seen = Set<URL>()
        for url in urls {
            try Task.checkCancellation()
            let folder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if folder {
                guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let child as URL in enumerator {
                    try Task.checkCancellation()
                    guard (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                          AudioMetadataReader.isCandidate(child), seen.insert(child.standardizedFileURL).inserted else { continue }
                    result.append(child)
                }
            } else if AudioMetadataReader.isCandidate(url) {
                if seen.insert(url.standardizedFileURL).inserted { result.append(url) }
            } else {
                rejected.append(url.lastPathComponent)
            }
        }
        return (result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }, rejected)
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
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let temporary = stagingDirectory.appendingPathComponent("\(UUID().uuidString).import")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: target)
    }
    /// Content-addressed: identical covers (every track of an album) share one file, so
    /// playlist mosaics show distinct artwork and the library does not store N copies.
    /// References are counted by the store before any file is removed.
    func saveArtwork(_ data: Data) throws -> String {
        let digest = SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
        let reference = "images/\(digest).image"
        try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
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
