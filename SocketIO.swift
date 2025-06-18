//
//  SocketIO.swift
//  Maple
//
//  Created by Potter on 4/21/25.
//

import SwiftUI
import SocketIO
import SwiftyJSON

class AppSocketManager: ObservableObject {
    static let shared = AppSocketManager()
    let enabled = UserDefaults.standard.bool(forKey: "socketIO")

    private var manager: SocketManager
    var socket: SocketIOClient

    init() {
        let cookies = HTTPCookieStorage.shared.cookies ?? []

        // print(cookies)
        // let cookieString = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        
        let config: SocketIOClientConfiguration = [
            .log(true), // Enable logging
            .cookies(cookies)
        ]
        // Initialize the SocketManager with the server URL
        manager = SocketManager(socketURL: URL(string: "https://maple.kolf.pro:3000")!, config: config)
        socket = manager.defaultSocket

        if enabled{
            connect()
        }

    }

    func connect() {
        socket.connect()
    }

    func disconnect() {
        socket.disconnect()
    }

    func onConnect() {
        socket.on(clientEvent: .connect) { data, ack in
            print("Connected to server")
        }
    }

    func nowPlaying(song: Song, id: String, discord: Bool) {
        // Check if the socket is connected before emitting
        if socket.status == .connected {
            // Create the song data
            let songData: [String: Any] = [
                "title": song.title,
                "artist": song.artist,
                "album": song.album,
                "id": id,
                "discord": discord
            ]
            
            // Wrap the song data in a dictionary with the key "nowPlaying"
            let payload: [String: Any] = ["nowPlaying": songData]
            
            // Convert payload to JSON
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: payload)
                if let jsonString = String(data: jsonData, encoding: .utf8) {
                    print("Payload being sent: \(jsonString)") // Print the JSON string
                }
            } catch {
                print("Error converting payload to JSON: \(error)")
            }
            
            // Emit the payload
            socket.emit("nowPlaying", payload)
        } else {
            print("Socket is not connected. Cannot emit nowPlaying event.")
        }
    }
    
    
}




// struct SocketIO: View {
//     var body: some View {
//         Text(/*@START_MENU_TOKEN@*/"Hello, World!"/*@END_MENU_TOKEN@*/)
//     }
// }

// #Preview {
//     SocketIO()
// }

