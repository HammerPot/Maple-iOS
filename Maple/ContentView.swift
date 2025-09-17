//
//  ContentView.swift
//  Maple
//
//  Created by Potter on 3/23/25.
//

import SwiftUI
import SocketIO
import MusicKit
import MusadoraKit
import SwiftUISnackbar

struct ContentView: View {
    @ObservedObject private var manager = AppleMusicManager.shared
    @ObservedObject private var audioManager = AudioPlayerManager.shared
    @ObservedObject private var socketManager = AppSocketManager.shared

    @ObservedObject private var amPlayer = AMPlayer.shared
    @State private var snackbar: Snackbar?
    @State private var showPlayer = false

    init() {
        // socketManager.connect()
        Task{
            // let nowSong3 = SystemMusicPlayer.shared.queue.currentEntry?.item?.id
            // print("nowSong3: \(nowSong3)")
            // let nowSong2 = SystemMusicPlayer.shared.queue.currentEntry
            // print("nowSong2: \(nowSong2)")
            // print("nowSong2.item: \(nowSong2?.song.item)")
            let nowSong = SystemMusicPlayer.shared.queue.currentEntry?.item
            print("nowSong: \(nowSong)")
            if let song = nowSong {
                print("song: \(song)")
                // dump(song)
            } else {
                print("No current song")
            }
            
            // print("SystemMusicPlayer.shared.queue.currentEntry?.item: \(SystemMusicPlayer.shared.queue.currentEntry?.item)")
            // print("SystemMusicPlayer.shared.queue.currentEntry: \(SystemMusicPlayer.shared.queue.currentEntry)")
            let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let imagePath = documentDirectory.appendingPathComponent("images")
	        do {
		        if !FileManager.default.fileExists(atPath: imagePath.path){
			        try FileManager.default.createDirectory(at: imagePath, withIntermediateDirectories: true, attributes: nil)
                    try UIImage(named: "Maple")?.pngData()?.write(to: imagePath.appendingPathComponent("maple.image"))
                }
            }
        }
        if UserDefaults.standard.bool(forKey: "musicKit") == true {
            manager.checkAuthorization()
        }
    }
    var body: some View {
        // Button(action: {
        //     snackbar = Snackbar(title: "Hello", message: "World")
        // }) {
        //     Text("Show Snackbar")
        // }
        if #available(iOS 26.0, *) {
            TabView {
                Tab("Home", systemImage: "house") {
                    Home()
                }
                Tab("Search", systemImage: "magnifyingglass", role: .search) {
                    Search()
                }
                Tab("Account", systemImage: "person.crop.circle") {
                    NavigationStack{
                        Login()
                    }
                }
                Tab("Settings", systemImage: "gear") {
                    Settings()
                }
            }
            .snackbarView(snackbar: $socketManager.snackbar)
            .snackbarView(snackbar: $snackbar)
            .zIndex(0)
            // .tabBarMinimizeBehavior(.onScrollDown)
            .tabViewBottomAccessory {
                NowPlayingBar(showPlayer: $showPlayer)
            }
            .sheet(isPresented: $showPlayer) {
                if amPlayer.initialized == true {
                    AMPlayerView2()
                }
                else {
                    MediaPlayerView(
                        song: audioManager.currentSong ?? Song(
                            id: UUID(), title: "No Song", artist: "No Artist", album: "No Album",
                            year: Int(Calendar(identifier: .gregorian).dateComponents([.year], from: .now).year ?? 2025), genre: "Unknown", duration: 0.0, artwork: nil,
                            trackNumber: 0, discNumber: 0, ext: "", url: URL(fileURLWithPath: "")
                        ),
                        allSongs: audioManager.queue
                    )
                }
            }
        } else {
            // Fallback on earlier versions
            TabView {
                Tab("Home", systemImage: "house") {
                    Home()
                }
                Tab("Now Playing", systemImage: "play.circle.fill"){
                    if amPlayer.initialized == true {
                        AMPlayerView2()
                    }
                    else {
                        MediaPlayerView(
                            song: audioManager.currentSong ?? Song(
                                id: UUID(), title: "No Song", artist: "No Artist", album: "No Album",
                                year: Int(Calendar(identifier: .gregorian).dateComponents([.year], from: .now).year ?? 2025), genre: "Unknown", duration: 0.0, artwork: nil,
                                trackNumber: 0, discNumber: 0, ext: "", url: URL(fileURLWithPath: "")
                            ),
                            allSongs: audioManager.queue
                        )
                    }
                }
                Tab("Search", systemImage: "magnifyingglass", role: .search) {
                    Search()
                }
                Tab("Account", systemImage: "person.crop.circle") {
                    NavigationStack{
                        Login()
                    }
                }
                Tab("Settings", systemImage: "gear") {
                    Settings()
                }
            }
            .snackbarView(snackbar: $socketManager.snackbar)
            .zIndex(0)
        }
    }

    // let manager = SocketManager(socketURL: URL(string: "https://api.maple.music")!, config: [.log(true)])
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
    // @Environment(\.openURL) private var openURL
    @ObservedObject private var audioManager = AudioPlayerManager.shared
    @ObservedObject private var amPlayer = AMPlayer.shared
    @Binding var showPlayer: Bool
    // @Environment(\.tabViewBottomAccessoryPlacement)
    // var placement

    var body: some View {

        if amPlayer.initialized == true{
            ZStack {
                    NavigationLink(
                        destination: AMPlayerView2(),
                        isActive: $showPlayer
                    ) { EmptyView() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    HStack(spacing: 12) {
                        Group {
                            // if let currentSong = SystemMusicPlayer.shared.queue.currentEntry?.item,
                            //    let artworkURL = currentSong.track.artwork?.url(width: 44, height: 44) {
                            //     AsyncImage(url: artworkURL) { image in
                            //         image.resizable()
                            //     } placeholder: {
                            //         if let uiImage = UIImage(named: "Maple") {
                            //             Image(uiImage: uiImage)
                            //                 .resizable()
                            //         }
                            //     }
                            // } else if let uiImage = UIImage(named: "Maple") {
                            //     Image(uiImage: uiImage)
                            //         .resizable()
                            // }
                            if let artwork = amPlayer.albumArt {
                                Image(uiImage: artwork)
                                        .resizable()
                                        // .scaledToFit()
                                        .frame(width: 30, height: 30)
                                        // .clipShape(RoundedRectangle(cornerRadius: 8))
                                        // .padding()

                            } else if let uiImage = UIImage(named: "Maple") {
                                Image(uiImage: uiImage)
                                    .resizable()
                            }
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxHeight: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            if let currentEntry = SystemMusicPlayer.shared.queue.currentEntry,
                               case .song(let song) = currentEntry.item {
                                Text(song.title)
                                    .font(.caption)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Text(song.artistName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            } else {
                                Text("No song playing")
                                    .font(.caption)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Text("Artist")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .layoutPriority(1)
                        Spacer(minLength: 8)
                        HStack(spacing: 12) {
                            Button(action: {
                                Task {
                                    if SystemMusicPlayer.shared.state.playbackStatus == .playing {
                                        SystemMusicPlayer.shared.pause()
                                    } else {
                                        try? await SystemMusicPlayer.shared.play()
                                    }
                                }
                            }) {
                                Image(systemName: amPlayer.isPlaying == true ? "pause.fill" : "play.fill")
                                    .font(.title3)
                            }
                            .buttonStyle(.borderless)

                            Button(action: {
                                Task {
                                    try? await SystemMusicPlayer.shared.skipToNextEntry()
                                }
                            }) {
                                Image(systemName: "forward.fill")
                                    .font(.title3)
                            }
                            .buttonStyle(.borderless)
                            Button(action: {
                                print("AM Button pressed")
                                UIApplication.shared.open(URL(string: "music://")!, options: [:], completionHandler: nil)
                            }){
                                Image(uiImage: UIImage(named: "AM")!)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 20, height: 20)
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
        } else {
            ZStack {
                NavigationLink(
                    destination: MediaPlayerView(song: audioManager.currentSong ?? Song(id: UUID(), title: "No Song", artist: "No Artist", album: "No Album", year: Int(Calendar(identifier: .gregorian).dateComponents([.year], from: .now).year ?? 2025), genre: "Unknown", duration: 0.0, artwork: nil, trackNumber: 0, discNumber: 0, ext: "", url: URL(fileURLWithPath: "")), allSongs: audioManager.queue),
                    isActive: $showPlayer
                ) { EmptyView() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                HStack(spacing: 12) {
                    Group {
                        if let currentSong = audioManager.currentSong,
                        let artwork = currentSong.artwork,
                        let uiImage = UIImage(contentsOfFile: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(artwork).path) {
                            Image(uiImage: uiImage)
                                .resizable()
                        } else if let uiImage = UIImage(named: "Maple") {
                            Image(uiImage: uiImage)
                                .resizable()
                        }
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxHeight: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
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
                    .layoutPriority(1)
                    Spacer(minLength: 8)
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
        }
    }
}

#Preview {
    ContentView()
}
