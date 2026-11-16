import Foundation
import Observation
import OSLog

@MainActor @Observable
final class LibraryStore {
    private(set) var tracks: [LibraryTrack] = []
    private(set) var playlists: [LibraryPlaylist] = []
    private(set) var albums: [LibraryAlbum] = []
    private(set) var artists: [LibraryArtist] = []
    private(set) var statistics: [UUID: TrackStatistics] = [:]
    private(set) var recentIDs: [UUID] = []
    private(set) var isLoaded = false
    private(set) var isLoading = false
    private(set) var progress: LibraryImportProgress?
    private(set) var importSummary: LibraryImportSummary?
    var errorMessage: String?
    let artworkCache = LibraryArtworkCache()
    let root: URL
    @ObservationIgnored private let disk: LibraryDisk
    @ObservationIgnored private let metadata: any LibraryMetadataReading
    @ObservationIgnored private var trackIndex: [UUID: LibraryTrack] = [:]
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var pendingFileRemovals: [String] = []
    @ObservationIgnored private var importing = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var deleting = false
    @ObservationIgnored private let logger = Logger(subsystem: "com.maple.library", category: "Library")
    /// Player adapter removes deleted IDs from its queue and stops a deleted current track.
    @ObservationIgnored var willDeleteTracks: ((Set<UUID>) -> Void)?

    init(root: URL, metadata: any LibraryMetadataReading = AudioMetadataReader()) {
        self.root = root; disk = LibraryDisk(root: root); self.metadata = metadata
    }
    deinit { saveTask?.cancel(); importTask?.cancel() }
    var recentlyPlayed: [LibraryTrack] { recentIDs.compactMap { trackIndex[$0] } }
    var recentlyAdded: [LibraryTrack] { Array(tracks.sorted { $0.dateAdded > $1.dateAdded }.prefix(12)) }
    func track(_ id: UUID) -> LibraryTrack? { trackIndex[id] }
    func tracks(ids: [UUID]) -> [LibraryTrack] { ids.compactMap { trackIndex[$0] } }
    func audioURL(for track: LibraryTrack) -> URL { root.appendingPathComponent("tracks").appendingPathComponent(track.fileName) }
    func artworkURL(_ reference: String?) -> URL? {
        guard let reference else { return nil }
        let name = URL(fileURLWithPath: reference).lastPathComponent
        return name.isEmpty ? nil : root.appendingPathComponent("images").appendingPathComponent(name)
    }
    func playlist(_ id: UUID) -> LibraryPlaylist? { playlists.first { $0.id == id } }

    func load() async {
        guard !isLoaded, !isLoading else { return }
        isLoading = true
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
        } catch { report(error) }
    }
    private var catalog: LibraryCatalog {
        LibraryCatalog(revision: revision, tracks: tracks, playlists: playlists, statistics: statistics, recentlyPlayed: recentIDs, pendingFileRemovals: pendingFileRemovals)
    }
    private func changed(rebuildGroups: Bool = false) {
        revision += 1
        if rebuildGroups { rebuild() }
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard let self else { return }
            self.saveTask = nil
            do { try await self.flush() } catch { self.report(error) }
        }
    }
    func flush() async throws {
        guard isLoaded else { throw LibraryError.notLoaded }
        let snapshot = catalog
        try await disk.save(snapshot)
    }
    private func report(_ error: Error) {
        logger.error("Library operation failed: \(error.localizedDescription, privacy: .public)")
        errorMessage = error.localizedDescription
    }
    private func rebuild() {
        trackIndex = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let grouped = Dictionary(grouping: tracks, by: \.albumKey)
        albums = grouped.map { key, songs in
            let ordered = songs.sorted {
                if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            let first = ordered[0]
            let names = Set(songs.map(\.artist))
            return LibraryAlbum(id: key, name: first.album, artist: first.albumArtist ?? (names.count == 1 ? first.artist : "Various Artists"),
                                artwork: ordered.compactMap(\.artwork).first, year: ordered.map(\.year).first { $0 > 0 } ?? 0, trackIDs: ordered.map(\.id))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        artists = Dictionary(grouping: tracks, by: { LibraryTrack.key($0.artist) }).map { key, songs in
            LibraryArtist(id: key, name: songs[0].artist, trackIDs: songs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.map(\.id),
                          albumIDs: Array(Set(songs.map(\.albumKey))))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func startImport(_ urls: [URL], scan: Bool = false) {
        guard isLoaded, progress == nil, !deleting else { return }
        importSummary = nil
        progress = LibraryImportProgress(completed: 0, total: 0, fileName: "Finding audio files…")
        importTask = Task { [weak self] in
            guard let self else { return }
            self.importSummary = await self.importFiles(urls, scan: scan)
            self.progress = nil
        }
    }
    func scanForNewFiles() { startImport([root], scan: true) }
    func cancelImport() { importTask?.cancel() }
    func dismissImportSummary() { importSummary = nil }

    /// Testable pipeline; security scopes stay open until enumeration, metadata and copying finish.
    func importFiles(_ urls: [URL], scan: Bool = false) async -> LibraryImportSummary {
        var summary = LibraryImportSummary()
        guard isLoaded, !deleting, !importing else { summary.failures = [LibraryError.notLoaded.localizedDescription]; return summary }
        importing = true
        defer { importing = false }
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let files = try await disk.candidates(in: urls)
            var keys = Set(tracks.map(\.duplicateKey))
            let knownFiles = Set(tracks.map(\.fileName))
            for (index, url) in files.enumerated() {
                try Task.checkCancellation()
                progress = LibraryImportProgress(completed: index, total: files.count, fileName: url.lastPathComponent)
                let inTracks = url.deletingLastPathComponent().standardizedFileURL == root.appendingPathComponent("tracks").standardizedFileURL
                if scan && inTracks && (knownFiles.contains(url.lastPathComponent) || pendingFileRemovals.contains("tracks/" + url.lastPathComponent)) { continue }
                do {
                    var imported = try await metadata.read(url)
                    try Task.checkCancellation()
                    guard !keys.contains(imported.track.duplicateKey) else { summary.duplicates += 1; continue }
                    let name = scan && inTracks ? url.lastPathComponent : "\(imported.track.id.uuidString).\(url.pathExtension.lowercased())"
                    imported.track.fileName = name
                    if let artwork = imported.artwork { imported.track.artwork = try await disk.saveArtwork(artwork) }
                    do {
                        if !(scan && inTracks) { try await disk.stageAudio(from: url, fileName: name, moving: scan) }
                    } catch {
                        if let reference = imported.track.artwork { try? await disk.removeFiles([reference]) }
                        throw error
                    }
                    tracks.append(imported.track); keys.insert(imported.track.duplicateKey)
                    summary.imported += 1
                    changed()
                    if summary.imported.isMultiple(of: 20) { rebuild(); try await flush() }
                } catch is CancellationError { throw CancellationError() }
                catch { summary.failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
        } catch is CancellationError { summary.cancelled = true }
        catch { summary.failures.append(error.localizedDescription) }
        rebuild()
        do { try await flush() } catch { report(error); summary.failures.append(error.localizedDescription) }
        progress = nil
        return summary
    }

    @discardableResult
    func createPlaylist(name: String, description: String = "", trackIDs: [UUID] = []) throws -> UUID {
        guard isLoaded else { throw LibraryError.notLoaded }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidName }
        let playlist = LibraryPlaylist(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), description: description,
            trackIDs: uniqueExisting(trackIDs), dateCreated: .now, dateModified: .now)
        playlists.append(playlist); changed(); return playlist.id
    }
    func updatePlaylist(_ id: UUID, name: String, description: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidName }
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        playlists[index].description = description; playlists[index].dateModified = .now; changed()
    }
    func setPlaylistArtwork(_ id: UUID, data: Data?) async throws {
        let reference: String?
        if let data { reference = try await disk.saveArtwork(data) } else { reference = nil }
        guard let index = playlists.firstIndex(where: { $0.id == id }) else {
            if let reference { try? await disk.removeFiles([reference]) }; return
        }
        let old = playlists[index].artwork
        playlists[index].artwork = reference; playlists[index].dateModified = .now; changed()
        try await flush()
        if let old, !usedArtwork.contains(old) { try await scheduleFileRemovals([old]) }
    }
    func addTracks(_ ids: [UUID], to playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].trackIDs = uniqueExisting(playlists[index].trackIDs + ids)
        playlists[index].dateModified = .now; changed()
    }
    func setPlaylistTracks(_ id: UUID, ids: [UUID]) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].trackIDs = uniqueExisting(ids); playlists[index].dateModified = .now; changed()
    }
    @discardableResult
    func duplicatePlaylist(_ id: UUID) throws -> UUID? {
        guard let original = playlist(id) else { return nil }
        let newID = try createPlaylist(name: original.name + " Copy", description: original.description, trackIDs: original.trackIDs)
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
    func deleteTrack(_ id: UUID) async throws { try await deleteTracks([id]) }
    func deleteAlbum(_ id: String) async throws {
        try await deleteTracks(Set(albums.first { $0.id == id }?.trackIDs ?? []))
    }
    func deleteArtist(_ id: String) async throws {
        try await deleteTracks(Set(artists.first { $0.id == id }?.trackIDs ?? []))
    }
    func deleteTracks(_ ids: Set<UUID>) async throws {
        guard progress == nil, !deleting, !importing else { throw LibraryError.busy }
        deleting = true; defer { deleting = false }
        try await removeTracks(ids)
    }
    private func removeTracks(_ ids: Set<UUID>) async throws {
        let removed = tracks.filter { ids.contains($0.id) }
        willDeleteTracks?(ids)
        tracks.removeAll { ids.contains($0.id) }
        for index in playlists.indices { playlists[index].trackIDs.removeAll { ids.contains($0) } }
        recentIDs.removeAll { ids.contains($0) }
        statistics = statistics.filter { !ids.contains($0.key) }
        changed(rebuildGroups: true)
        let audio = removed.map { "tracks/" + $0.fileName }.filter { reference in !tracks.contains { "tracks/" + $0.fileName == reference } }
        let artwork = Set(removed.compactMap(\.artwork)).subtracting(usedArtwork)
        try await scheduleFileRemovals(audio + artwork)
    }
    func clearLibrary() async throws {
        guard progress == nil, !deleting, !importing else { throw LibraryError.busy }
        deleting = true; defer { deleting = false }
        let playlistArtwork = Set(playlists.compactMap(\.artwork))
        try await removeTracks(Set(tracks.map(\.id)))
        playlists = []; recentIDs = []; statistics = [:]; changed(); try await flush()
        try await scheduleFileRemovals(Array(playlistArtwork))
        try await disk.removeLegacyCatalogs()
    }
    private func scheduleFileRemovals(_ references: [String]) async throws {
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
    func recordStart(_ id: UUID, at date: Date = .now) {
        guard trackIndex[id] != nil else { return }
        var stats = statistics[id, default: TrackStatistics()]
        stats.plays += 1; stats.lastPlayed = date; statistics[id] = stats
        recentIDs.removeAll { $0 == id }; recentIDs.insert(id, at: 0); recentIDs = Array(recentIDs.prefix(30)); changed()
    }
    func recordListening(_ id: UUID, seconds: Double) {
        guard trackIndex[id] != nil, seconds.isFinite, seconds > 0, seconds <= 5 else { return }
        statistics[id, default: TrackStatistics()].listeningSeconds += seconds; changed()
    }
    func recordEnd(_ id: UUID, completed: Bool) {
        guard trackIndex[id] != nil else { return }
        if completed { statistics[id, default: TrackStatistics()].completions += 1 }
        else { statistics[id, default: TrackStatistics()].skips += 1 }
        changed()
    }
    func clearRecentlyPlayed() { recentIDs = []; changed() }
}
