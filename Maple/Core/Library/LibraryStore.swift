import Foundation
import Observation
import OSLog

/// Owns the local library in memory and persists it through `LibraryDisk`.
///
/// Tracks and playlists are the source of truth; albums and artists are derived on change.
/// Mutations are synchronous on the main actor; saving is debounced and runs off the main
/// thread on the disk actor. File deletions are journaled in the catalog first, so a crash
/// mid-delete is finished on the next launch.
@MainActor @Observable
final class LibraryStore {
    private(set) var tracks: [LibraryTrack] = []
    private(set) var playlists: [LibraryPlaylist] = []
    private(set) var albums: [LibraryAlbum] = []
    private(set) var artists: [LibraryArtist] = []
    private(set) var recentlyAdded: [LibraryTrack] = []
    private(set) var statistics: [UUID: TrackStatistics] = [:]
    private(set) var recentIDs: [UUID] = []
    private(set) var isLoaded = false
    private(set) var isLoading = false
    /// Why the catalog could not be opened; the library stays unloaded until `load` succeeds.
    private(set) var loadError: String?
    /// Non-nil while an import or scan runs.
    private(set) var progress: LibraryImportProgress?
    /// Result of the last user-started import, shown by the import sheet.
    private(set) var importSummary: LibraryImportSummary?
    /// Failures to surface to the user; the shell shows them as a toast.
    var errorMessage: String?
    /// Short positive notices (e.g. files picked up from the Files app).
    var announcement: String?
    let artworkCache = LibraryArtworkCache()
    let root: URL

    @ObservationIgnored private let disk: LibraryDisk
    @ObservationIgnored private let metadata: any LibraryMetadataReading
    @ObservationIgnored private var trackIndex: [UUID: LibraryTrack] = [:]
    @ObservationIgnored private var albumIndex: [String: LibraryAlbum] = [:]
    @ObservationIgnored private var artistIndex: [String: LibraryArtist] = [:]
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var pendingFileRemovals: [String] = []
    /// Listening time is reported many times a second; it is folded into `statistics` in batches.
    @ObservationIgnored private var pendingListening: [UUID: Double] = [:]
    /// Files a scan already rejected this session (duplicates, unplayable), keyed by path.
    @ObservationIgnored private var scanIgnored: Set<String> = []
    @ObservationIgnored private var importing = false
    @ObservationIgnored private var deleting = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.maple.library", category: "Library")

    /// Called before tracks are removed so the player can drop them from its queue and stop
    /// a deleted current track.
    @ObservationIgnored var willDeleteTracks: ((Set<UUID>) -> Void)?

    static let recentLimit = 30

    /// - Parameters:
    ///   - root: media folder containing `tracks/` and `images/` (the app's Documents).
    ///   - catalogDirectory: private catalog folder; defaults to `root/library` for tests.
    init(root: URL, catalogDirectory: URL? = nil, metadata: any LibraryMetadataReading = AudioMetadataReader()) {
        self.root = root
        disk = LibraryDisk(root: root, catalogDirectory: catalogDirectory)
        self.metadata = metadata
    }

    // MARK: Lookup

    var recentlyPlayed: [LibraryTrack] { recentIDs.compactMap { trackIndex[$0] } }
    func track(_ id: UUID) -> LibraryTrack? { trackIndex[id] }
    func tracks(ids: [UUID]) -> [LibraryTrack] { ids.compactMap { trackIndex[$0] } }
    func album(_ id: String) -> LibraryAlbum? { albumIndex[id] }
    func artist(_ id: String) -> LibraryArtist? { artistIndex[id] }
    func album(for track: LibraryTrack) -> LibraryAlbum? { albumIndex[track.albumKey] }
    func artist(for track: LibraryTrack) -> LibraryArtist? { artistIndex[track.artistKey] }
    func playlist(_ id: UUID) -> LibraryPlaylist? { playlists.first { $0.id == id } }
    func statistics(for id: UUID) -> TrackStatistics { statistics[id] ?? TrackStatistics() }

    /// Where the player loads a track's audio from.
    func audioURL(for track: LibraryTrack) -> URL { root.appendingPathComponent("tracks").appendingPathComponent(track.fileName) }
    /// Full-size artwork file for a track or playlist `artwork` reference.
    func artworkURL(_ reference: String?) -> URL? {
        guard let reference else { return nil }
        let name = URL(fileURLWithPath: reference).lastPathComponent
        return name.isEmpty || name == "/" ? nil : root.appendingPathComponent("images").appendingPathComponent(name)
    }

    // MARK: Loading and saving

    func load() async {
        guard !isLoaded, !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let (catalog, warning) = try await disk.load()
            tracks = catalog.tracks; playlists = catalog.playlists
            statistics = catalog.statistics; recentIDs = catalog.recentlyPlayed; revision = catalog.revision
            pendingFileRemovals = catalog.pendingFileRemovals
            rebuild(); isLoaded = true; errorMessage = warning
            if !pendingFileRemovals.isEmpty {
                do { try await finishFileRemovals() } catch { report(error) }
            }
        } catch {
            logger.error("Library could not be opened: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
        }
    }

    private var catalog: LibraryCatalog {
        LibraryCatalog(revision: revision, tracks: tracks, playlists: playlists, statistics: statistics,
                       recentlyPlayed: recentIDs, pendingFileRemovals: pendingFileRemovals)
    }

    /// Marks the catalog dirty and schedules a debounced save. Statistics-only changes use a
    /// longer delay: they arrive constantly during playback and are cheap to lose.
    private func changed(rebuildGroups: Bool = false, saveAfter delay: Duration = .milliseconds(600)) {
        revision += 1
        if rebuildGroups { rebuild() }
        let deadline = ContinuousClock.now + delay
        if let saveDeadline, saveDeadline <= deadline, saveTask != nil { return }
        saveTask?.cancel()
        saveDeadline = deadline
        saveTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard let self else { return }
            self.saveTask = nil; self.saveDeadline = nil
            do { try await self.flush() } catch { self.report(error) }
        }
    }

    /// Writes the current state now. Call when the app leaves the foreground.
    func flush() async throws {
        guard isLoaded else { throw LibraryError.notLoaded }
        foldListening()
        try await disk.save(catalog)
    }

    private func report(_ error: Error) {
        logger.error("Library operation failed: \(error.localizedDescription, privacy: .public)")
        errorMessage = error.localizedDescription
    }

    private func rebuild() {
        trackIndex = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        albums = LibraryGrouping.albums(from: tracks)
        artists = LibraryGrouping.artists(from: tracks)
        albumIndex = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        artistIndex = Dictionary(artists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        recentlyAdded = Array(tracks.sorted { $0.dateAdded > $1.dateAdded }.prefix(50))
    }

    // MARK: Import

    /// Starts a user-visible import of picked files/folders; progress and the summary are
    /// published on `progress` and `importSummary`.
    func startImport(_ urls: [URL]) {
        guard isLoaded, progress == nil, !deleting else { return }
        importSummary = nil
        importTask = Task { [weak self] in
            guard let self else { return }
            let summary = await self.importFiles(urls)
            self.importSummary = summary
        }
    }

    /// Picks up audio dropped into the app's Documents folder (Files app, AirDrop "Open in").
    /// Files outside `tracks/` are moved into it; files already in `tracks/` are adopted in place.
    /// Silent scans only announce tracks that were actually added.
    func scanForNewFiles(silently: Bool = false) {
        guard isLoaded, progress == nil, !deleting, !importing else { return }
        if !silently { importSummary = nil }
        importTask = Task { [weak self] in
            guard let self else { return }
            let summary = await self.importFiles([self.root], scan: true)
            if !silently { self.importSummary = summary }
            else if summary.imported > 0 {
                self.announcement = summary.imported == 1 ? "Added 1 track from the Files app" : "Added \(summary.imported) tracks from the Files app"
            }
        }
    }

    func cancelImport() { importTask?.cancel() }
    func dismissImportSummary() { importSummary = nil }

    /// The import pipeline. Security scopes stay open until enumeration, metadata reading and
    /// copying finish. Duplicates (same title and artist) are skipped before any audio is copied.
    func importFiles(_ urls: [URL], scan: Bool = false) async -> LibraryImportSummary {
        var summary = LibraryImportSummary()
        guard isLoaded, !deleting, !importing else { summary.failures = [LibraryError.busy.localizedDescription]; return summary }
        importing = true
        progress = LibraryImportProgress(completed: 0, total: 0, fileName: scan ? "Looking for new files…" : "Finding audio files…")
        defer { importing = false; progress = nil }
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in scoped { url.stopAccessingSecurityScopedResource() } }
        let tracksFolder = root.appendingPathComponent("tracks").standardizedFileURL.resolvingSymlinksInPath()
        var addedSinceCheckpoint = 0
        do {
            let found = try await disk.candidates(in: urls)
            summary.failures += found.rejected.map { "\($0): \(LibraryError.notAudio.localizedDescription)" }
            var keys = Set(tracks.map(\.duplicateKey))
            let knownFiles = Set(tracks.map(\.fileName))
            let files = scan ? found.files.filter { url in
                let inTracks = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == tracksFolder
                if inTracks && (knownFiles.contains(url.lastPathComponent) || pendingFileRemovals.contains("tracks/" + url.lastPathComponent)) { return false }
                return !scanIgnored.contains(url.standardizedFileURL.path)
            } : found.files
            for (index, url) in files.enumerated() {
                try Task.checkCancellation()
                progress = LibraryImportProgress(completed: index, total: files.count, fileName: url.lastPathComponent)
                let adoptInPlace = scan && url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == tracksFolder
                do {
                    var imported = try await metadata.read(url)
                    try Task.checkCancellation()
                    guard !keys.contains(imported.track.duplicateKey) else {
                        summary.duplicates += 1
                        if scan { scanIgnored.insert(url.standardizedFileURL.path) }
                        continue
                    }
                    let name = adoptInPlace ? url.lastPathComponent : "\(imported.track.id.uuidString).\(url.pathExtension.lowercased())"
                    imported.track.fileName = name
                    if let artwork = imported.artwork { imported.track.artwork = try await disk.saveArtwork(artwork) }
                    do {
                        if !adoptInPlace { try await disk.stageAudio(from: url, fileName: name, moving: scan) }
                    } catch {
                        if let reference = imported.track.artwork { try? await disk.removeFiles([reference]) }
                        throw error
                    }
                    tracks.append(imported.track)
                    trackIndex[imported.track.id] = imported.track
                    keys.insert(imported.track.duplicateKey)
                    summary.imported += 1; addedSinceCheckpoint += 1
                    changed()
                    // Publish groups and checkpoint the catalog periodically during big imports.
                    if addedSinceCheckpoint >= 25 { addedSinceCheckpoint = 0; rebuild(); try await flush() }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    if scan { scanIgnored.insert(url.standardizedFileURL.path) }
                    summary.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        } catch is CancellationError { summary.cancelled = true }
        catch { summary.failures.append(error.localizedDescription) }
        rebuild()
        do { try await flush() } catch { report(error); summary.failures.append(error.localizedDescription) }
        if summary.imported > 0 || !summary.failures.isEmpty {
            logger.notice("Import finished: \(summary.imported) imported, \(summary.duplicates) duplicates, \(summary.failures.count) failed, cancelled: \(summary.cancelled)")
        }
        return summary
    }

    // MARK: Playlists

    @discardableResult
    func createPlaylist(name: String, description: String = "", trackIDs: [UUID] = []) throws -> UUID {
        guard isLoaded else { throw LibraryError.notLoaded }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw LibraryError.invalidName }
        let playlist = LibraryPlaylist(id: UUID(), name: clean, description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                                       trackIDs: uniqueExisting(trackIDs), dateCreated: .now, dateModified: .now)
        playlists.append(playlist); changed(); return playlist.id
    }

    func updatePlaylist(_ id: UUID, name: String, description: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw LibraryError.invalidName }
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = clean
        playlists[index].description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        playlists[index].dateModified = .now; changed()
    }

    /// Sets custom artwork from image data, or clears it (`nil`) to use the automatic mosaic.
    func setPlaylistArtwork(_ id: UUID, data: Data?) async throws {
        let reference: String? = if let data { try await disk.saveArtwork(data) } else { nil }
        guard let index = playlists.firstIndex(where: { $0.id == id }) else {
            if let reference { try? await disk.removeFiles([reference]) }
            return
        }
        let old = playlists[index].artwork
        playlists[index].artwork = reference; playlists[index].dateModified = .now; changed()
        try await flush()
        if let old, !usedArtwork.contains(old) { try await scheduleFileRemovals([old]) }
    }

    /// Appends tracks, ignoring ones already in the playlist. Returns how many were added.
    @discardableResult
    func addTracks(_ ids: [UUID], to playlistID: UUID) -> Int {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return 0 }
        let before = playlists[index].trackIDs.count
        playlists[index].trackIDs = uniqueExisting(playlists[index].trackIDs + ids)
        playlists[index].dateModified = .now; changed()
        return playlists[index].trackIDs.count - before
    }

    func removeTracks(_ ids: Set<UUID>, from playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].trackIDs.removeAll { ids.contains($0) }
        playlists[index].dateModified = .now; changed()
    }

    func moveTracks(in playlistID: UUID, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].trackIDs.move(fromOffsets: source, toOffset: destination)
        playlists[index].dateModified = .now; changed()
    }

    func setPlaylistTracks(_ id: UUID, ids: [UUID]) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].trackIDs = uniqueExisting(ids); playlists[index].dateModified = .now; changed()
    }

    @discardableResult
    func duplicatePlaylist(_ id: UUID) throws -> UUID? {
        guard let original = playlist(id) else { return nil }
        let newID = try createPlaylist(name: original.name + " (Copy)", description: original.description, trackIDs: original.trackIDs)
        // Artwork files are shared by reference and only removed when no playlist uses them.
        if let index = playlists.firstIndex(where: { $0.id == newID }) { playlists[index].artwork = original.artwork; changed() }
        return newID
    }

    private func uniqueExisting(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { trackIndex[$0] != nil && seen.insert($0).inserted }
    }

    private var usedArtwork: Set<String> { Set(tracks.compactMap(\.artwork) + playlists.compactMap(\.artwork)) }

    func deletePlaylist(_ id: UUID) async throws {
        let old = playlist(id)?.artwork
        playlists.removeAll { $0.id == id }; changed(); try await flush()
        if let old, !usedArtwork.contains(old) { try await scheduleFileRemovals([old]) }
    }

    // MARK: Deletion

    func deleteTrack(_ id: UUID) async throws { try await deleteTracks([id]) }
    func deleteAlbum(_ id: String) async throws { try await deleteTracks(Set(albumIndex[id]?.trackIDs ?? [])) }
    func deleteArtist(_ id: String) async throws { try await deleteTracks(Set(artistIndex[id]?.trackIDs ?? [])) }

    /// Removes tracks, their audio, now-unused artwork, statistics, recent entries and
    /// playlist memberships.
    func deleteTracks(_ ids: Set<UUID>) async throws {
        guard !ids.isEmpty else { return }
        guard progress == nil, !deleting, !importing else { throw LibraryError.busy }
        deleting = true; defer { deleting = false }
        try await removeTracksAndFiles(ids)
    }

    private func removeTracksAndFiles(_ ids: Set<UUID>) async throws {
        let removed = tracks.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        willDeleteTracks?(ids)
        tracks.removeAll { ids.contains($0.id) }
        for index in playlists.indices where playlists[index].trackIDs.contains(where: ids.contains) {
            playlists[index].trackIDs.removeAll { ids.contains($0) }
            playlists[index].dateModified = .now
        }
        recentIDs.removeAll { ids.contains($0) }
        statistics = statistics.filter { !ids.contains($0.key) }
        for id in ids { pendingListening[id] = nil }
        changed(rebuildGroups: true)
        let stillUsed = Set(tracks.map(\.fileName))
        let audio = removed.map(\.fileName).filter { !stillUsed.contains($0) }.map { "tracks/" + $0 }
        let artwork = Set(removed.compactMap(\.artwork)).subtracting(usedArtwork)
        try await scheduleFileRemovals(audio + artwork)
    }

    /// Deletes every track, audio file, artwork, playlist, statistic and recent entry.
    func clearLibrary() async throws {
        guard progress == nil, !deleting, !importing else { throw LibraryError.busy }
        deleting = true; defer { deleting = false }
        let playlistArtwork = Set(playlists.compactMap(\.artwork))
        try await removeTracksAndFiles(Set(tracks.map(\.id)))
        playlists = []; recentIDs = []; statistics = [:]; pendingListening = [:]; scanIgnored = []
        changed(); try await flush()
        try await scheduleFileRemovals(Array(playlistArtwork))
        try await disk.removeLegacyCatalogs()
    }

    private func scheduleFileRemovals(_ references: [String]) async throws {
        guard !references.isEmpty else { return }
        pendingFileRemovals = Array(Set(pendingFileRemovals + references))
        changed()
        try await flush()
        try await finishFileRemovals()
    }

    private func finishFileRemovals() async throws {
        let references = pendingFileRemovals
        try await disk.removeFiles(references)
        pendingFileRemovals.removeAll { references.contains($0) }
        changed(); try await flush()
    }

    // MARK: Recently played and statistics (called by the player)

    /// A track began playing (not a resume). Counts a play and moves it to the front of
    /// recently played.
    func recordStart(_ id: UUID, at date: Date = .now) {
        guard trackIndex[id] != nil else { return }
        var stats = statistics[id] ?? TrackStatistics()
        stats.plays += 1; stats.lastPlayed = date; statistics[id] = stats
        recentIDs.removeAll { $0 == id }
        recentIDs.insert(id, at: 0)
        if recentIDs.count > Self.recentLimit { recentIDs.removeLast(recentIDs.count - Self.recentLimit) }
        changed()
    }

    /// Wall-clock seconds actually listened since the previous report. Implausible samples
    /// (seeks, clock jumps) are ignored.
    func recordListening(_ id: UUID, seconds: Double) {
        guard trackIndex[id] != nil, seconds.isFinite, seconds > 0, seconds <= 5 else { return }
        pendingListening[id, default: 0] += seconds
        if pendingListening[id, default: 0] >= 15 { foldListening() }
    }

    /// The track stopped being current. `completed` is true only when it reached its end
    /// naturally; anything else (next, previous, a new queue, deletion) is a skip.
    func recordEnd(_ id: UUID, completed: Bool) {
        guard trackIndex[id] != nil else { return }
        foldListening()
        if completed { statistics[id, default: TrackStatistics()].completions += 1 }
        else { statistics[id, default: TrackStatistics()].skips += 1 }
        changed(saveAfter: .seconds(5))
    }

    func clearRecentlyPlayed() { recentIDs = []; changed() }

    private func foldListening() {
        guard !pendingListening.isEmpty else { return }
        for (id, seconds) in pendingListening where trackIndex[id] != nil {
            statistics[id, default: TrackStatistics()].listeningSeconds += seconds
        }
        pendingListening = [:]
        changed(saveAfter: .seconds(10))
    }
}
