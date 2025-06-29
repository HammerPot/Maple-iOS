//
//  AM.swift
//  Maple
//
//  Created by Potter on 6/25/25.
//

import SwiftUI
import MusicKit

class AppleMusicManager: ObservableObject {
    static let shared = AppleMusicManager()

    @Published var authStatus: MusicAuthorization.Status = .notDetermined
    @Published var sub: MusicSubscription?
    @Published var libSongs: MusicLibraryResponse<MusicKit.Song>?
    @Published var libAlbums: MusicLibraryResponse<MusicKit.Album>?
    @Published var libPlaylists: MusicLibraryResponse<MusicKit.Playlist>?
    @Published var libArtists: MusicLibraryResponse<MusicKit.Artist>?
    
    func requestAuthorization() {
        Task {
            authStatus = await MusicAuthorization.request()
        }
    }

    func checkAuthorization() {
        authStatus = MusicAuthorization.currentStatus
        if authStatus == .authorized {
            getSubStatus()
        }
    }

    func getSubStatus() {
        Task {
            do {
                sub = try await MusicSubscription.current
                print(sub)
                // Notify on main thread that subscription status has been updated
                await MainActor.run {
                    // This will trigger UI updates
                }
            } catch {
                print("Error getting subscription status: \(error)")
            }
        }
    }

    func getLibrarySongs() async -> ([MusicKit.Song], [Song]) {
        do {
            libSongs = try await MusicLibraryRequest<MusicKit.Song>().response()
            if let libSongs = libSongs {
                let mkSongs = Array(libSongs.items ?? [])
                for song in mkSongs {
                    print(song.url)
                }
                let songs = mkSongs.map { song in
                Song(
                        id: UUID(),
                        title: song.title ?? "Unknown",
                        artist: song.artistName ?? "Unknown",
                        album: song.albumTitle ?? "Unknown",
                        year: 0000,
                        genre: song.genreNames.isEmpty ? "Unknown" : song.genreNames[0] ?? "Unknown",
                        duration: song.duration ?? 0,
                        artwork: song.artwork?.url(width: 160, height: 160)?.absoluteString ?? nil,
                        trackNumber: song.trackNumber ?? 0,
                        discNumber: song.discNumber ?? 0,
                        ext: "ApM",
                        url: song.url ?? URL(fileURLWithPath: "")
                    )
                }

                return (mkSongs, songs)
            }
        } catch {
            print("Error getting library: \(error)")
        }
        return ([], [])
    }

    func getLibraryAlbums() async -> [MusicKit.Album] {
        do {
            libAlbums = try await MusicLibraryRequest<MusicKit.Album>().response()
            return Array(libAlbums?.items ?? [])
        } catch {
            print("Error getting library: \(error)")
        }
        return []
    }

    func getLibraryPlaylists() async -> [MusicKit.Playlist] {
        do {
            libPlaylists = try await MusicLibraryRequest<MusicKit.Playlist>().response()
            return Array(libPlaylists?.items ?? [])
        } catch {
            print("Error getting library: \(error)")
        }
        return []
    }

    func getLibraryArtists() async -> [MusicKit.Artist] {
        do {
            libArtists = try await MusicLibraryRequest<MusicKit.Artist>().response()
            return Array(libArtists?.items ?? [])
        } catch {
            print("Error getting library: \(error)")
        }
        return []
    }
}



struct AppleMusic: View {
    @StateObject private var manager = AppleMusicManager.shared

    init() {
        manager.checkAuthorization()


    }

    var body: some View {
        NavigationView {
            VStack {
                if manager.sub?.canPlayCatalogContent == true {
                    List {
                        NavigationLink("Tracks", destination: AppleMusicTracks())
                        NavigationLink("Albums", destination: AppleMusicAlbums())
                        NavigationLink("Artists", destination: AppleMusicArtists())
                        NavigationLink("Playlists", destination: AppleMusicPlaylists())
                    }
                    .navigationTitle("Apple Music")
                } else {
                    Text("You cannot play catalog content. Please subscribe to Apple Music to use this feature. If you are already subscribed, please try again later or report this issue to the developer.")
                }
            }
        }
    }
}

struct AppleMusicTracks: View {
    @StateObject private var manager = AppleMusicManager.shared
    @State private var songsMK: [MusicKit.Song] = []
    @State private var songs: [Song] = []
    @State private var isLoading = true

    var body: some View {
        List {
            if isLoading {
                ProgressView("Loading songs...")
            } else {
                ForEach(songs) { song in
                    NavigationLink(destination: AudioPlayerView(song: song, allSongs: songs.sorted(by: { $0.title < $1.title }))) {
                        Text(song.title)
                    }
                }
            }
        }
        .task {
            (songsMK, songs) = await manager.getLibrarySongs()
            print(songs)
            isLoading = false
        }
    }
}

struct AppleMusicAlbums: View {
    @StateObject private var manager = AppleMusicManager.shared
    @State private var albums: [MusicKit.Album] = []
    @State private var isLoading = true

    var body: some View {
        List {
            if isLoading {
                ProgressView("Loading albums...")
            } else {
                ForEach(albums) { album in
                    Text(album.title)
                }
            }
        }
        .task {
            albums = await manager.getLibraryAlbums()
            isLoading = false
        }
    }
}

struct AppleMusicArtists: View {
    @StateObject private var manager = AppleMusicManager.shared
    @State private var artists: [MusicKit.Artist] = []
    @State private var isLoading = true

    var body: some View {
        List {
            if isLoading {
                ProgressView("Loading artists...")
            } else {
                ForEach(artists) { artist in
                    Text(artist.name)
                }
            }
        }
        .task {
            artists = await manager.getLibraryArtists()
            isLoading = false
        }
    }
}

struct AppleMusicPlaylists: View {
    @StateObject private var manager = AppleMusicManager.shared
    @State private var playlists: [MusicKit.Playlist] = []
    @State private var isLoading = true

    var body: some View {
        List {
            if isLoading {
                ProgressView("Loading playlists...")
            } else {
                ForEach(playlists) { playlist in
                    Text(playlist.name)
                }
            }
        }
        .task {
            playlists = await manager.getLibraryPlaylists()
            isLoading = false
        }
    }
}






#Preview {
    AppleMusic()
}
