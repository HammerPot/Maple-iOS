//
//  ContentView.swift
//  Maple
//
//  Created by Potter on 3/23/25.
//

import SwiftUI
import SocketIO

struct ContentView: View {
    let socketManager = AppSocketManager.shared
    init() {
        // socketManager.connect()
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
            Tab("Search", systemImage: "magnifyingglass") {
            }
            Tab("Account", systemImage: "person.crop.circle") {
                Login()
            }
            Tab("Settings", systemImage: "gear") {
                Settings()
            }
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


#Preview {
    ContentView()
}
