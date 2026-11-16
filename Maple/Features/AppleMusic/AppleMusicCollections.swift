import SwiftUI
import MusicKit

struct AppleMusicAlbums: View {
    @Environment(AppleMusicService.self) private var service
    var body: some View { AppleMusicAlbumGrid(title: "Albums", load: { try await service.albums() }) }
}
struct AppleMusicArtistView: View {
    @Environment(AppleMusicService.self) private var service
    let artist: MusicKit.Artist
    var body: some View { AppleMusicAlbumGrid(title: artist.name, load: { try await service.albums(by: artist) }) }
}
struct AppleMusicAlbumGrid: View {
    let title: String
    let load: () async throws -> [MusicKit.Album]
    @State private var albums: [MusicKit.Album] = []
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        ScrollView {
            if loading { ProgressView("Loading albums…") }
            if let error { AppleMusicLoadError(message: error, retry: reload).padding() }
            if !loading && albums.isEmpty && error == nil { Text("No albums found").foregroundStyle(.secondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 240))], spacing: 16) {
                ForEach(albums) { album in
                    NavigationLink { AppleMusicAlbumView(album: album) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            AsyncImage(url: album.artwork?.url(width: 400, height: 400)) { image in image.resizable().scaledToFill() } placeholder: {
                                Rectangle().fill(.quaternary).overlay { Image(systemName: "music.note").foregroundStyle(.secondary) }
                            }
                            .aspectRatio(1, contentMode: .fit).clipShape(.rect(cornerRadius: 8)).accessibilityHidden(true)
                            Text(album.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                            Text(album.artistName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            Text("\(album.trackCount) tracks").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding()
        }
        .navigationTitle(title).task { await reload() }.refreshable { await reload() }
    }
    private func reload() async {
        loading = true; error = nil
        defer { loading = false }
        do { albums = try await load().sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
        catch { self.error = error.localizedDescription }
    }
}
struct AppleMusicArtists: View {
    @Environment(AppleMusicService.self) private var service
    @State private var artists: [MusicKit.Artist] = []
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        List {
            if loading { ProgressView("Loading artists…") }
            if let error { AppleMusicLoadError(message: error, retry: reload) }
            if !loading && artists.isEmpty && error == nil { Text("No artists found").foregroundStyle(.secondary) }
            ForEach(artists) { artist in NavigationLink(artist.name) { AppleMusicArtistView(artist: artist) } }
        }.navigationTitle("Artists").task { await reload() }.refreshable { await reload() }
    }
    private func reload() async {
        loading = true; error = nil
        defer { loading = false }
        do { artists = try await service.artists().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        catch { self.error = error.localizedDescription }
    }
}
struct AppleMusicPlaylists: View {
    @Environment(AppleMusicService.self) private var service
    @State private var playlists: [MusicKit.Playlist] = []
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        List {
            if loading { ProgressView("Loading playlists…") }
            if let error { AppleMusicLoadError(message: error, retry: reload) }
            if !loading && playlists.isEmpty && error == nil { Text("No playlists found").foregroundStyle(.secondary) }
            ForEach(playlists) { playlist in NavigationLink(playlist.name) { AppleMusicPlaylistView(playlist: playlist) } }
        }.navigationTitle("Playlists").task { await reload() }.refreshable { await reload() }
    }
    private func reload() async {
        loading = true; error = nil
        defer { loading = false }
        do { playlists = try await service.playlists() } catch { self.error = error.localizedDescription }
    }
}
