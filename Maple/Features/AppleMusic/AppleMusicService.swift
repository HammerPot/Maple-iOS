import Foundation
import MusicKit
import Observation
import OSLog

@MainActor @Observable final class AppleMusicService {
    private(set) var authStatus = MusicAuthorization.currentStatus
    private(set) var canPlayCatalog = false
    private(set) var errorMessage: String?
    let engine: AppleMusicPlaybackEngine
    init(engine: AppleMusicPlaybackEngine) { self.engine = engine }
    var authorizationLabel: String {
        switch authStatus {
        case .authorized: "Allowed"
        case .denied: "Denied — allow access in iOS Settings"
        case .restricted: "Restricted on this device"
        case .notDetermined: "Not requested"
        @unknown default: "Unavailable"
        }
    }
    func refreshAuthorization(request: Bool = false) async {
        guard UserDefaults.standard.bool(forKey: "musicKit") else { canPlayCatalog = false; return }
        authStatus = request ? await MusicAuthorization.request() : MusicAuthorization.currentStatus
        guard authStatus == .authorized else { return }
        do { canPlayCatalog = try await MusicSubscription.current.canPlayCatalogContent }
        catch { errorMessage = error.localizedDescription }
    }
    private func all<Item: MusicItem & Decodable>(_ first: MusicItemCollection<Item>) async throws -> [Item] {
        var result = Array(first), batch = first
        while batch.hasNextBatch {
            try Task.checkCancellation()
            guard let next = try await batch.nextBatch() else { break }
            result.append(contentsOf: next); batch = next
        }
        return result
    }
    func songs() async throws -> [MusicKit.Track] {
        let response = try await MusicLibraryRequest<MusicKit.Song>().response()
        let tracks = try await all(response.items).map { MusicKit.Track.song($0) }
        // This source is known to be the library even if its raw IDs happen to be numeric.
        AppleMusicDiagnostics.logger.info("resolution source=library-browse requested=all returned=\(tracks.count, privacy: .public) numeric=\(tracks.filter { UInt64($0.id.rawValue) != nil }.count, privacy: .public) sample=[\(AppleMusicDiagnostics.ids(Array(tracks.prefix(3)).map { $0.id.rawValue } + Array(tracks.suffix(3)).map { $0.id.rawValue }), privacy: .public)]")
        engine.register(tracks)
        return tracks
    }
    func albums() async throws -> [MusicKit.Album] { try await all(MusicLibraryRequest<MusicKit.Album>().response().items) }
    func artists() async throws -> [MusicKit.Artist] { try await all(MusicLibraryRequest<MusicKit.Artist>().response().items) }
    func playlists() async throws -> [MusicKit.Playlist] { try await all(MusicLibraryRequest<MusicKit.Playlist>().response().items) }
    func tracks(in album: MusicKit.Album) async throws -> [MusicKit.Track] {
        let tracks = try await all(album.with(.tracks).tracks ?? [])
        engine.register(tracks); return tracks
    }
    func tracks(in playlist: MusicKit.Playlist) async throws -> [MusicKit.Track] {
        let tracks = try await all(playlist.with(.tracks).tracks ?? [])
        engine.register(tracks); return tracks
    }
    func albums(by artist: MusicKit.Artist) async throws -> [MusicKit.Album] { try await all(artist.with(.albums).albums ?? []) }
}
