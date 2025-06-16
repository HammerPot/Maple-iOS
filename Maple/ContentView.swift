//
//  ContentView.swift
//  Maple
//
//  Created by Potter on 3/23/25.
//

import SwiftUI
import SocketIO

struct ContentView: View {
    @ObservedObject private var audioManager = AudioPlayerManager.shared
    let socketManager = AppSocketManager.shared

    @State private var showPlayer = false

    init() {
        // socketManager.connect()
        Task{
            let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let imagePath = documentDirectory.appendingPathComponent("images")
	        do {
		        if !FileManager.default.fileExists(atPath: imagePath.path){
			        try FileManager.default.createDirectory(at: imagePath, withIntermediateDirectories: true, attributes: nil)
                    try UIImage(named: "Maple")?.pngData()?.write(to: imagePath.appendingPathComponent("maple.image"))
                }
            }
        }
    }
    var body: some View {
        // MusicButton()
        // Button(action: {
        //         // Example of sending now playing data
        //         let song = Song(url: URL(string: "https://example.com/song.mp3")!, title: "Song Title", artist: "Artist Name", album: "Album Name", artwork: nil, trackNumber: 1, discNumber: 1) // Replace with your Song model
        //         socketManager.nowPlaying(song: song, id: "934591a1-8d85-4f7a-bddb-4a63e44fc70f", discord: false) // Replace with actual song ID
        //     }) {
        //         Text("Send Now Playing")
        //     }
        
            TabView {
                Tab("Home", systemImage: "house") {
                    Home()
                }
                Tab("Search", systemImage: "magnifyingglass", role: .search) {
                    Search()
                }
                Tab("Account", systemImage: "person.crop.circle") {
                    Login()
                }
                Tab("Settings", systemImage: "gear") {
                    Settings()
                }
            }
            // .tabBarMinimizeBehavior(.onScrollDown)
            .tabViewBottomAccessory {
                NowPlayingBar(showPlayer: $showPlayer)
            }
            .sheet(isPresented: $showPlayer) {
                MediaPlayerView(
                    song: audioManager.currentSong ?? Song(
                        id: UUID(), title: "No Song", artist: "No Artist", album: "No Album",
                        year: 2024, genre: "Unknown", duration: 0.0, artwork: nil,
                        trackNumber: 0, discNumber: 0, ext: "", url: URL(fileURLWithPath: "")
                    ),
                    allSongs: audioManager.queue
                )
            }
    }

    // let manager = SocketManager(socketURL: URL(string: "https://maple.kolf.pro:3000")!, config: [.log(true)])
    // let socket = manager.defaultSocket

    // init() {
    //     socket.connect()
    //     socket.on(clientEvent: .connect) { data, ack in
    //         print("Connected to server")
    //     }
    //     socket.on(clientEvent: .disconnect) { data, ack in
    //         print("Disconnected from server")
    //     }
    // }
    
}


struct NowPlayingBar: View {
    @ObservedObject private var audioManager = AudioPlayerManager.shared
    @Binding var showPlayer: Bool
    // @Environment(\.tabViewBottomAccessoryPlacement)
    // var placement

    var body: some View {

        // if placement == .inline {
        //     ZStack {
        //         // Transparent NavigationLink (see previous step)
        //         NavigationLink(
        //             destination: MediaPlayerView(song: audioManager.currentSong ?? Song(id: UUID(), title: "No Song", artist: "No Artist", album: "No Album", year: Int(Calendar(identifier: .gregorian).dateComponents([.year], from: .now).year ?? 2024), genre: "Unknown", duration: 0.0, artwork: nil, trackNumber: 0, discNumber: 0, ext: "", url: URL(fileURLWithPath: "")), allSongs: audioManager.queue),
        //             isActive: $showPlayer
        //         ) { EmptyView() }
        //         .frame(maxWidth: .infinity, maxHeight: .infinity)
        //         .contentShape(Rectangle())

        //         HStack(spacing: 8) {
        //             // Artwork
        //             Group {
        //                 if let currentSong = audioManager.currentSong,
        //                 let artwork = currentSong.artwork,
        //                 let uiImage = UIImage(contentsOfFile: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(artwork).path) {
        //                     Image(uiImage: uiImage)
        //                         .resizable()
        //                 } else if let uiImage = UIImage(contentsOfFile: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("images/maple.image").path) {
        //                     Image(uiImage: uiImage)
        //                         .resizable()
        //                 }
        //             }
        //             .aspectRatio(1, contentMode: .fit)
        //             .frame(width: 32, height: 32)
        //             .clipShape(RoundedRectangle(cornerRadius: 6))

        //             // Song info
        //             VStack(alignment: .leading, spacing: 0) {
        //                 Text(audioManager.currentSong?.title ?? "No song playing")
        //                     .font(.subheadline)
        //                     .fontWeight(.semibold)
        //                     .foregroundColor(.primary)
        //                     .lineLimit(1)
        //                 Text(audioManager.currentSong?.artist ?? "Artist")
        //                     .font(.caption2)
        //                     .foregroundColor(.secondary)
        //                     .lineLimit(1)
        //             }
        //             .layoutPriority(1)

        //             Spacer(minLength: 6)

        //             // Play/Pause button only
        //             Button(action: {
        //                 if audioManager.isPlaying {
        //                     audioManager.pause()
        //                 } else {
        //                     audioManager.play()
        //                 }
        //             }) {
        //                 Image(systemName: audioManager.isPlaying ? "pause.fill" : "play.fill")
        //                     .font(.title3)
        //             }
        //             .buttonStyle(.borderless)
        //         }
        //         .padding(.vertical, 4)
        //         .padding(.horizontal, 10)
        //         .frame(maxWidth: .infinity, minHeight: 0, maxHeight: 40, alignment: .center)
        //         .contentShape(Rectangle())
        //     }
        //     .onTapGesture {
        //         showPlayer = true
        //     }
        // } else {
        // NavigationStack{
            ZStack {
                // Transparent NavigationLink (see previous step)
                NavigationLink(
                    destination: MediaPlayerView(song: audioManager.currentSong ?? Song(id: UUID(), title: "No Song", artist: "No Artist", album: "No Album", year: Int(Calendar(identifier: .gregorian).dateComponents([.year], from: .now).year ?? 2024), genre: "Unknown", duration: 0.0, artwork: nil, trackNumber: 0, discNumber: 0, ext: "", url: URL(fileURLWithPath: "")), allSongs: audioManager.queue),
                    isActive: $showPlayer
                ) { EmptyView() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())

                // The bar content
                HStack(spacing: 12) {
                    // Artwork
                    Group {
                        if let currentSong = audioManager.currentSong,
                        let artwork = currentSong.artwork,
                        let uiImage = UIImage(contentsOfFile: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(artwork).path) {
                            Image(uiImage: uiImage)
                                .resizable()
                        } else if let uiImage = UIImage(contentsOfFile: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("images/maple.image").path) {
                            Image(uiImage: uiImage)
                                .resizable()
                        }
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxHeight: 44) // Max height, but will shrink if needed
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    // Song info
                    VStack(alignment: .leading, spacing: 2) {
                        Text(audioManager.currentSong?.title ?? "No song playing")
                            .font(.caption)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(audioManager.currentSong?.artist ?? "Artist")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .layoutPriority(1) // Give text more space

                    Spacer(minLength: 8)

                    // Controls
                    HStack(spacing: 12) {
                        Button(action: {
                            if audioManager.isPlaying {
                                audioManager.pause()
                            } else {
                                audioManager.play()
                            }
                        }) {
                            Image(systemName: audioManager.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)

                        Button(action: {
                            audioManager.playNext()
                        }) {
                            Image(systemName: "forward.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: 56, alignment: .center)
            }
            .onTapGesture {
                showPlayer = true
            }
        // }
    }
}

#Preview {
    ContentView()
}
