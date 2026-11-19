import SwiftUI
import MusicKit

struct AppleMusic: View {
    @Environment(AppleMusicService.self) private var service
    @AppStorage("musicKit") private var enabled = false
    var body: some View {
        List {
            if enabled && service.authStatus == .authorized {
                NavigationLink("Tracks") { AppleMusicTracks() }
                NavigationLink("Albums") { AppleMusicAlbums() }
                NavigationLink("Artists") { AppleMusicArtists() }
                NavigationLink("Playlists") { AppleMusicPlaylists() }
                if !service.canPlayCatalog {
                    Text("An Apple Music subscription is required for catalog playback. Your available library is shown below.").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView("Apple Music Access", systemImage: "music.note",
                    description: Text(enabled ? service.authorizationLabel : "Enable Apple Music in Settings to browse your library."))
                if enabled && service.authStatus == .notDetermined {
                    Button("Allow Apple Music Access") { Task { await service.refreshAuthorization(request: true) } }
                }
            }
        }
        .navigationTitle("Apple Music")
        .task { await service.refreshAuthorization() }
    }
}

struct AppleMusicTracks: View {
    @Environment(AppleMusicService.self) private var service
    var body: some View { AppleMusicTrackList(title: "Tracks", load: { try await service.songs() }) }
}
struct AppleMusicAlbumView: View {
    @Environment(AppleMusicService.self) private var service
    let album: MusicKit.Album
    var body: some View { AppleMusicTrackList(title: album.title, load: { try await service.tracks(in: album) }) }
}
struct AppleMusicPlaylistView: View {
    @Environment(AppleMusicService.self) private var service
    let playlist: MusicKit.Playlist
    var body: some View { AppleMusicTrackList(title: playlist.name, load: { try await service.tracks(in: playlist) }) }
}

struct AppleMusicTrackList: View {
    @Environment(PlaybackController.self) private var player
    let title: String
    let load: () async throws -> [MusicKit.Track]
    @State private var tracks: [MusicKit.Track] = []
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        List {
            if loading { ProgressView("Loading tracks…") }
            if let error { AppleMusicLoadError(message: error, retry: reload) }
            if !loading && tracks.isEmpty && error == nil { Text("No tracks found").foregroundStyle(.secondary) }
            ForEach(tracks) { track in
                Button { play(track) } label: {
                    VStack(alignment: .leading) {
                        Text(track.title).foregroundStyle(.primary)
                        Text(track.artistName).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.enqueue([AppleMusicPlaybackEngine.item(track)], next: true) }
                    Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { player.enqueue([AppleMusicPlaybackEngine.item(track)], next: false) }
                }
            }
        }
        .navigationTitle(title)
        .task { await reload() }
        .refreshable { await reload() }
    }
    private func reload() async {
        loading = true; error = nil
        defer { loading = false }
        do { tracks = try await load() } catch { self.error = error.localizedDescription }
    }
    private func play(_ track: MusicKit.Track) {
        let items = tracks.map(AppleMusicPlaybackEngine.item)
        let index = tracks.firstIndex { $0.id == track.id } ?? 0
        Task { await player.start(items, startingAt: index) }
    }
}

struct AppleMusicLoadError: View {
    let message: String
    let retry: () async -> Void
    var body: some View {
        Section {
            Text(message).foregroundStyle(.secondary)
            Button("Try Again") { Task { await retry() } }
        }
    }
}
