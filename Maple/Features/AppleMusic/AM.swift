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
    @Published var libSongs: MusicLibraryResponse<MusicKit.Track>?
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

    func getLibrarySongs() async -> [MusicKit.Track] {
        do {
            libSongs = try await MusicLibraryRequest<MusicKit.Track>().response()
            let libTracks = try await MusicLibraryRequest<MusicKit.Song>().response()
            // print("libTracks: \(libTracks)")
            if let libSongs = libSongs {
                let mkSongs = Array(libSongs.items ?? [])
                // print("libSongs: \(libSongs)")
                // print("mkSongs: \(mkSongs[0])")
                
                // let songs = mkSongs.map { song in
                // Song(
                //         id: UUID(),
                //         title: song.title ?? "Unknown",
                //         artist: song.artistName ?? "Unknown",
                //         album: song.albumTitle ?? "Unknown",
                //         year: 0000,
                //         genre: song.genreNames.isEmpty ? "Unknown" : song.genreNames[0] ?? "Unknown",
                //         duration: song.duration ?? 0,
                //         artwork: song.artwork?.url(width: 160, height: 160)?.absoluteString ?? nil,
                //         trackNumber: song.trackNumber ?? 0,
                //         discNumber: song.discNumber ?? 0,
                //         ext: "ApM",
                //         url: song.url ?? URL(fileURLWithPath: "")
                //     )
                // }

                // return (mkSongs, songs)
                return mkSongs
            }
        } catch {
            print("Error getting library: \(error)")
        }
        return []
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

    func getLibraryAlbum(album: MusicKit.Album) async -> [MusicKit.Track] {
        do {
            let detailedAlbum = try await album.with(.tracks)
            return Array(detailedAlbum.tracks ?? [])
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
    @State private var songsMK: [MusicKit.Track] = []
    // @State private var songs: [Song] = []
    @State private var isLoading = true
    
    // Group songs by first character
    private var groupedSongs: [(String, [MusicKit.Track])] {
        let grouped = Dictionary(grouping: songsMK.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }) { song in
            let firstChar = song.title.prefix(1).uppercased()
            if firstChar.rangeOfCharacter(from: .letters) != nil {
                return String(firstChar)
            } else {
                return "#"
            }
        }
        return grouped.sorted { $0.key < $1.key }
    }

    var body: some View {
        List {
            if isLoading {
                ProgressView("Loading songs...")
            } else if songsMK.isEmpty {
                Text("No songs found")
                    .font(.headline)
                    .foregroundColor(.gray)
            } else {
                ForEach(groupedSongs, id: \.0) { section in
                    Section(header: Text(section.0).font(.title2).fontWeight(.bold)) {
                        ForEach(section.1) { song in
                            NavigationLink(destination: AMPlayerView(song: song, allSongs: [song], type: "song")) {
                                Text(song.title)
                            }
                        }
                    }
                }
            }
        }
        .task {
            songsMK = await manager.getLibrarySongs()
            // print(songs)
            isLoading = false
        }
    }
}

struct AppleMusicAlbums: View {
    @StateObject private var manager = AppleMusicManager.shared
    @State private var albums: [MusicKit.Album] = []
    @State private var isLoading = true
    
    private let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 16)
    ]
    
    // Group albums by first character
    private var groupedAlbums: [(String, [MusicKit.Album])] {
        let grouped = Dictionary(grouping: albums.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }) { album in
            let firstChar = album.title.prefix(1).uppercased()
            if firstChar.rangeOfCharacter(from: .letters) != nil {
                return String(firstChar)
            } else {
                return "#"
            }
        }
        return grouped.sorted { $0.key < $1.key }
    }

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView("Loading albums...")
                    .padding()
            } else if albums.isEmpty {
                Text("No albums found")
                    .font(.headline)
                    .foregroundColor(.gray)
                    .padding()
            } else {
                LazyVStack(spacing: 20) {
                    ForEach(groupedAlbums, id: \.0) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            // Section header
                            HStack {
                                Text(section.0)
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.primary)
                                Spacer()
                            }
                            .padding(.horizontal)
                            
                            // Albums grid for this section
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(section.1) { album in
                                    NavigationLink(destination: AppleMusicAlbumView(album: album)) {
                                        VStack(alignment: .leading) {
                                            if let artwork = album.artwork {
                                                AsyncImage(url: artwork.url(width: 160, height: 160)) { image in
                                                    image
                                                        .resizable()
                                                        .aspectRatio(contentMode: .fill)
                                                        .frame(width: 160, height: 160)
                                                        .cornerRadius(8)
                                                } placeholder: {
                                                    Rectangle()
                                                        .fill(Color.gray.opacity(0.2))
                                                        .frame(width: 160, height: 160)
                                                        .cornerRadius(8)
                                                        .overlay(
                                                            ProgressView()
                                                        )
                                                }
                                            } else {
                                                Rectangle()
                                                    .fill(Color.gray.opacity(0.2))
                                                    .frame(width: 160, height: 160)
                                                    .cornerRadius(8)
                                                    .overlay(
                                                        Image(systemName: "music.note")
                                                            .font(.system(size: 40))
                                                            .foregroundColor(.gray)
                                                    )
                                            }
                                            
                                            Text(album.title)
                                                .font(.headline)
                                                .foregroundColor(.primary)
                                                .lineLimit(1)
                                            
                                            Text(album.artistName)
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                            
                                            Text("\(album.trackCount) tracks")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        .frame(width: 160)
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical)
            }
        }
        .navigationTitle("Albums")
        .task {
            albums = await manager.getLibraryAlbums()
            isLoading = false
        }
    }
}

struct AppleMusicAlbumView: View {
    @StateObject private var manager = AppleMusicManager.shared
    @State private var album: MusicKit.Album
    @State private var tracks: [MusicKit.Track] = []

    init(album: MusicKit.Album) {
        self.album = album
    }

    var body: some View {
        Text(album.title)
        List {
            ForEach(tracks) { track in
                NavigationLink(destination: AMPlayerView(song: track, allSongs: Array(tracks), type: "album")) {
                    Text(track.title)
                }
            }
        }
        .onAppear {
            print("Album: \(album.title)")
            print("Tracks: \(album.tracks)")
            print("Tracks count: \(album.tracks?.count ?? 0)")
            print("Full Album: \(album)")
        }
        .task {
            do {
                let detailedAlbum = try await album.with(.tracks)
                tracks = Array(detailedAlbum.tracks ?? [])
                // isLoading = false
            } catch {
                print("Error getting library: \(error)")
            }
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
                    NavigationLink(destination: AppleMusicArtistView(artist: artist)) {
                        Text(artist.name)
                    }
                }
            }
        }
        .task {
            artists = await manager.getLibraryArtists()
            isLoading = false
        }
    }
}

struct AppleMusicArtistView: View {
    @State private var artist: MusicKit.Artist
    @StateObject private var manager = AppleMusicManager.shared
    @State private var albums: [MusicKit.Album] = []
    @State private var isLoading = true
    
    init(artist: MusicKit.Artist) {
        self.artist = artist
    }


    private let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 16)
    ]
    
    // Group albums by first character
    private var groupedAlbums: [(String, [MusicKit.Album])] {
        let grouped = Dictionary(grouping: albums.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }) { album in
            let firstChar = album.title.prefix(1).uppercased()
            if firstChar.rangeOfCharacter(from: .letters) != nil {
                return String(firstChar)
            } else {
                return "#"
            }
        }
        return grouped.sorted { $0.key < $1.key }
    }

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView("Loading albums...")
                    .padding()
            } else if albums.isEmpty {
                Text("No albums found")
                    .font(.headline)
                    .foregroundColor(.gray)
                    .padding()
            } else {
                LazyVStack(spacing: 20) {
                    ForEach(groupedAlbums, id: \.0) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            // Section header
                            HStack {
                                Text(section.0)
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.primary)
                                Spacer()
                            }
                            .padding(.horizontal)
                            
                            // Albums grid for this section
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(section.1) { album in
                                    NavigationLink(destination: AppleMusicAlbumView(album: album)) {
                                        VStack(alignment: .leading) {
                                            if let artwork = album.artwork {
                                                AsyncImage(url: artwork.url(width: 160, height: 160)) { image in
                                                    image
                                                        .resizable()
                                                        .aspectRatio(contentMode: .fill)
                                                        .frame(width: 160, height: 160)
                                                        .cornerRadius(8)
                                                } placeholder: {
                                                    Rectangle()
                                                        .fill(Color.gray.opacity(0.2))
                                                        .frame(width: 160, height: 160)
                                                        .cornerRadius(8)
                                                        .overlay(
                                                            ProgressView()
                                                        )
                                                }
                                            } else {
                                                Rectangle()
                                                    .fill(Color.gray.opacity(0.2))
                                                    .frame(width: 160, height: 160)
                                                    .cornerRadius(8)
                                                    .overlay(
                                                        Image(systemName: "music.note")
                                                            .font(.system(size: 40))
                                                            .foregroundColor(.gray)
                                                    )
                                            }
                                            
                                            Text(album.title)
                                                .font(.headline)
                                                .foregroundColor(.primary)
                                                .lineLimit(1)
                                            
                                            Text(album.artistName)
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                            
                                            Text("\(album.trackCount) tracks")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        .frame(width: 160)
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical)
            }
        }
        .navigationTitle("Albums")
        .task {
            do {
                let detailedArtist = try await artist.with(.albums)
                albums = Array(detailedArtist.albums ?? [])
            } catch {
                print("Error getting library: \(error)")
            }
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
                    NavigationLink(destination: AppleMusicPlaylistView(playlist: playlist)) {
                        Text(playlist.name)
                    }
                }
            }
        }
        .task {
            playlists = await manager.getLibraryPlaylists()
            isLoading = false
        }
    }
}

struct AppleMusicPlaylistView: View {
    @State private var playlist: MusicKit.Playlist
    @State private var tracks: [MusicKit.Track] = []
    @State private var isLoading = true

    init(playlist: MusicKit.Playlist) {
        self.playlist = playlist
    }

    var body: some View {
        Text(playlist.name)
        List {
            ForEach(tracks) { track in
                NavigationLink(destination: AMPlayerView(song: track, allSongs: Array(tracks), type: "playlist")) {
                    Text(track.title)
                }
            }
        }
        .task {
            do {
                let detailedPlaylist = try await playlist.with(.tracks)
                tracks = Array(detailedPlaylist.tracks ?? [])
                isLoading = false
            } catch {
                print("Error getting library: \(error)")
            }
        }
    }
}






#Preview {
    AppleMusic()
}
