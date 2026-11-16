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
    private let fileSystem: any LibraryFileSystem
    init(root: URL, catalogDirectory: URL? = nil, fileSystem: any LibraryFileSystem = DiskFileSystem()) {
        self.root = root
        self.fileSystem = fileSystem
        self.catalogDirectory = catalogDirectory ?? root.appendingPathComponent("library")
    }
    private var catalogURL: URL { catalogDirectory.appendingPathComponent("catalog.json") }
    private var backupURL: URL { catalogDirectory.appendingPathComponent("catalog.backup.json") }
    /// Staging area for copies; on the same volume as `tracks/` so the final move is atomic.
    private var stagingDirectory: URL { root.appendingPathComponent("tracks/.staging") }

    /// Opens the catalog. Order of preference: the primary, then its backup, then (only when
    /// neither file ever existed) the legacy JSON files. A catalog written by a newer schema is
    /// never replaced, archived or downgraded, whichever of the two files carries it.
    func load() throws -> (LibraryCatalog, String?) {
        try fileSystem.createDirectory(catalogDirectory)
        try fileSystem.createDirectory(root.appendingPathComponent("tracks"))
        try fileSystem.createDirectory(root.appendingPathComponent("images"))
        removeStaging()
        if fileSystem.exists(catalogURL) {
            do { return try openCatalog(catalogURL, label: "catalog") }
            catch is CorruptCatalog {
                logger.error("Catalog is damaged")
                // Look at the backup before touching anything: a backup written by a newer
                // version (or one we cannot read right now) must stop the load untouched.
                var backup: (LibraryCatalog, String?)?
                if fileSystem.exists(backupURL) {
                    do { backup = try openCatalog(backupURL, label: "backup") } catch is CorruptCatalog { backup = nil }
                }
                try archive(catalogURL, as: "corrupt")
                if let backup { return (backup.0, backup.1 ?? "Your library was recovered from its backup.") }
                if fileSystem.exists(backupURL) { try archive(backupURL, as: "corrupt-backup") }
                return (LibraryCatalog(), Self.damagedMessage)
            }
        }
        if fileSystem.exists(backupURL) {
            do {
                let backup = try openCatalog(backupURL, label: "backup")
                return (backup.0, backup.1 ?? "Your library was recovered from its backup.")
            } catch is CorruptCatalog {
                try archive(backupURL, as: "corrupt-backup")
                return (LibraryCatalog(), Self.damagedMessage)
            }
        }
        let (migrated, warning) = try migrateLegacy()
        try save(migrated)
        return (migrated, warning)
    }
    private static let damagedMessage = "The library catalog was damaged. Scan for new files to recover your audio. The original catalog has been kept."

    /// A readable but partly malformed catalog keeps its good rows; the original is archived
    /// first so nothing in it is lost when the cleaned catalog is saved over it.
    private func openCatalog(_ url: URL, label: String) throws -> (LibraryCatalog, String?) {
        let catalog = try decode(url)
        guard catalog.skippedRows > 0 else { return (catalog, nil) }
        logger.error("\(label, privacy: .public) had \(catalog.skippedRows) unreadable rows")
        try archive(url, as: "partial")
        return (catalog, "\(catalog.skippedRows) entries in your library could not be read and were set aside. Scan for new files to recover your audio.")
    }
    private func archive(_ url: URL, as prefix: String) throws {
        try fileSystem.copy(url, to: catalogDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString).json"))
    }

    /// Thrown for content that is not a usable version-1 catalog. I/O errors and
    /// `LibraryError.unsupportedVersion` are deliberately different: they never trigger recovery.
    private struct CorruptCatalog: Error { var underlying: any Error }

    private func decode(_ url: URL) throws -> LibraryCatalog {
        let data = try fileSystem.read(url)
        struct Header: Decodable { let version: Int }
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: data) } catch { throw CorruptCatalog(underlying: error) }
        guard header.version == 1 else { throw LibraryError.unsupportedVersion(header.version) }
        var result: LibraryCatalog
        do { result = try JSONDecoder().decode(LibraryCatalog.self, from: data) } catch { throw CorruptCatalog(underlying: error) }
        let safe = result.tracks.filter { !$0.fileName.isEmpty && $0.fileName == URL(fileURLWithPath: $0.fileName).lastPathComponent }
        result.skippedRows += result.tracks.count - safe.count
        result.tracks = safe
        savedRevision = result.revision
        return result
    }
    func save(_ catalog: LibraryCatalog) throws {
        guard catalog.revision >= savedRevision else { return }
        let data = try JSONEncoder().encode(catalog)
        try fileSystem.write(data, to: catalogURL)
        savedRevision = catalog.revision
        // Backup is a second independently atomic copy of the latest successful checkpoint.
        try fileSystem.write(data, to: backupURL)
    }

    /// Copies are staged here before the final move. A process killed mid-copy leaves its
    /// partial file behind, so the folder is emptied whenever the library opens (nothing can be
    /// importing yet) and when the library is cleared.
    func removeStaging() {
        guard fileSystem.exists(stagingDirectory) else { return }
        do { try fileSystem.remove(stagingDirectory) }
        catch { logger.error("Could not remove abandoned imports: \(error.localizedDescription, privacy: .public)") }
    }

    /// Everything the library owns inside `tracks/` and `images/`, including files no catalog
    /// entry refers to (orphans, legacy JSON, partial imports).
    func mediaInventory() throws -> [String] {
        var references: [String] = []
        for folder in ["tracks", "images"] {
            let url = root.appendingPathComponent(folder)
            guard fileSystem.exists(url) else { continue }
            for child in try fileSystem.contents(of: url) where !(folder == "tracks" && child.lastPathComponent == ".staging") {
                references.append(folder + "/" + child.lastPathComponent)
            }
        }
        return references
    }

    /// One-shot import of the pre-5.0 JSON files. Runs only when no catalog (or backup) exists,
    /// and the result is saved immediately, so it can never run twice. Audio is left in place.
    ///
    /// Rows are salvaged one by one. A source that exists but cannot be *read* (as opposed to
    /// parsed) aborts the migration without saving, so the next launch retries instead of
    /// finalising an incomplete library. Legacy files are never modified.
    private func migrateLegacy() throws -> (LibraryCatalog, String?) {
        var result = LibraryCatalog()
        var fileNames = Set<String>()
        var ids = Set<UUID>()
        var missingAudio = 0
        var primaryDamaged = false, snapshotDamaged = false
        var primaryUsable = false
        // Album/artist snapshots embed full song copies, so they can salvage tracks when
        // tracks.json is missing or corrupt. tracks.json is read first and wins.
        for path in ["tracks/tracks.json", "albums/albums.json", "artists/artists.json"] {
            let isPrimary = path.hasPrefix("tracks/")
            let url = root.appendingPathComponent(path)
            guard fileSystem.exists(url) else { continue }
            let data = try fileSystem.read(url)
            guard let elements = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
                logger.error("Legacy \(path, privacy: .public) is not a JSON array; skipping it")
                if isPrimary { primaryDamaged = true } else { snapshotDamaged = true }
                continue
            }
            if isPrimary { primaryUsable = true }
            var songs: [[String: Any]] = []
            var skipped = 0
            for element in elements {
                guard let object = element as? [String: Any] else { skipped += 1; continue }
                if isPrimary { songs.append(object); continue }
                guard let embedded = object["songs"] else { continue }
                guard let list = embedded as? [Any] else { skipped += 1; continue }
                for song in list {
                    if let dictionary = song as? [String: Any] { songs.append(dictionary) } else { skipped += 1 }
                }
            }
            for object in songs {
                // `url` was an absolute path inside a container that changes between installs;
                // only its last path component is trustworthy.
                // JSONEncoder writes URL as a string; other encoders use {"relative": …}.
                guard let urlString = object["url"] as? String ?? (object["url"] as? [String: Any])?["relative"] as? String else { skipped += 1; continue }
                let fileName = (URL(string: urlString) ?? URL(fileURLWithPath: urlString)).lastPathComponent
                guard !fileName.isEmpty, fileName != "/" else { skipped += 1; continue }
                guard !fileNames.contains(fileName) else { continue }
                let audio = root.appendingPathComponent("tracks").appendingPathComponent(fileName)
                guard fileSystem.exists(audio) else { missingAudio += 1; continue }
                fileNames.insert(fileName)
                var id = (object["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
                if !ids.insert(id).inserted { id = UUID(); ids.insert(id) }
                // Legacy artwork is "/images/<uuid>.image", relative to Documents.
                let artwork = (object["artwork"] as? String).flatMap { reference -> String? in
                    let name = URL(fileURLWithPath: reference).lastPathComponent
                    guard !name.isEmpty, name != "/" else { return nil }
                    return fileSystem.exists(root.appendingPathComponent("images").appendingPathComponent(name)) ? "images/" + name : nil
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
            if skipped > 0 {
                logger.error("Legacy \(path, privacy: .public): \(skipped) unreadable entries skipped")
                if isPrimary { primaryDamaged = true } else { snapshotDamaged = true }
            }
        }
        if !result.tracks.isEmpty || missingAudio > 0 {
            logger.notice("Migrated \(result.tracks.count) legacy tracks; \(missingAudio) entries had no audio file and were dropped")
        }
        // Damage in a snapshot only matters when it was needed to stand in for tracks.json.
        let warn = primaryDamaged || (!primaryUsable && snapshotDamaged)
        return (result, warn ? "Some entries from your previous library could not be read. Scan for new files to recover your audio." : nil)
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
            try fileSystem.move(source, to: target)
            return
        }
        try fileSystem.createDirectory(stagingDirectory)
        let temporary = stagingDirectory.appendingPathComponent("\(UUID().uuidString).import")
        defer { try? fileSystem.remove(temporary) }
        try fileSystem.copy(source, to: temporary)
        try Task.checkCancellation()
        try fileSystem.move(temporary, to: target)
    }
    /// Content-addressed: identical covers (every track of an album) share one file, so
    /// playlist mosaics show distinct artwork and the library does not store N copies.
    /// References are counted by the store before any file is removed.
    func saveArtwork(_ data: Data) throws -> String {
        let digest = SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
        let reference = "images/\(digest).image"
        try fileSystem.createDirectory(root.appendingPathComponent("images"))
        try fileSystem.write(data, to: root.appendingPathComponent(reference))
        return reference
    }
    func removeLegacyCatalogs() throws {
        for path in ["tracks/tracks.json", "albums/albums.json", "artists/artists.json"] {
            let url = root.appendingPathComponent(path)
            if fileSystem.exists(url) { try fileSystem.remove(url) }
        }
    }

    /// Removes each file independently; one stubborn file does not stop the others. Returns the
    /// references that are now gone (or were never valid and can never be removed) plus the
    /// first error, so the caller can keep the rest on its journal.
    func removeFiles(_ references: [String]) -> (done: Set<String>, firstError: (any Error)?) {
        var done = Set<String>()
        var firstError: (any Error)?
        for reference in Set(references) {
            let parts = reference.split(separator: "/")
            guard parts.count == 2, ["tracks", "images"].contains(String(parts[0])), !parts.contains("..") else {
                logger.error("Dropping unsafe journal entry")
                done.insert(reference); continue
            }
            let url = root.appendingPathComponent(reference)
            do {
                if fileSystem.exists(url) { try fileSystem.remove(url) }
                done.insert(reference)
            } catch {
                firstError = firstError ?? error
            }
        }
        return (done, firstError)
    }
}
