//
//  SocketIO.swift
//  Maple
//
//  Created by Potter on 4/21/25.
//

import SwiftUI
import SocketIO
import SwiftyJSON
import MusicKit
import MediaPlayer
import SwiftUISnackbar

class AppSocketManager: ObservableObject {
    static let shared = AppSocketManager()
    let enabled = UserDefaults.standard.bool(forKey: "socketIO")

    @Published var snackbar: Snackbar?

    private var manager: SocketManager
    var socket: SocketIOClient

    init() {
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        
        let config: SocketIOClientConfiguration = [
            .log(true),
            .cookies(cookies)
        ]
        manager = SocketManager(socketURL: URL(string: "https://api.maple.music")!, config: config)
        socket = manager.defaultSocket

        // Set up listeners
        setupListeners()
        
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

    func setupListeners() {
        // Set up connection listener
        socket.on(clientEvent: .connect) { data, ack in
            print("Connected to server")
        }
        
        // Set up friend request listener
        socket.on("friendRequest") { data, ack in
            let json = JSON(data)
            let id = json[0]["id"].stringValue
            // print(data)
            // print("--------------------------------")
            // print(json)
            // print("--------------------------------")
            // print(id)
            // print("--------------------------------")
            // print("Friend request received: \(id)")
            Task {
                do {
                    let response = try await publicUserId(serverID: id)
                    let username = response["username"]?.stringValue ?? "Unknown"
                    self.snackbar = Snackbar(title: "Friend request received", message: "Friend request received from \(username)", action: .text("Accept", .white, {
                        self.acceptF(id: id)
                    }))
                } catch {
                    self.snackbar = Snackbar(title: "Friend request received", message: "\(error.localizedDescription)")
                }
            }
            // self.snackbar = Snackbar(title: "Friend request received", message: "Friend request received from \(id)", action: .text("Accept", {
            //     self.acceptF(id: id)
            // }))

            // TODO: Handle friend request (show notification, update UI, etc.)
        }
        socket.on("requestAccepted") { data, ack in
            let json = JSON(data)
            let id = json[0]["id"].stringValue
            // print(data)
            // print("--------------------------------")
            // print(json)
            // print("--------------------------------")
            // print(id)
            // print("--------------------------------")
            // print("Friend request accepted: \(id)")
            self.snackbar = Snackbar(title: "Friend request accepted", message: "Friend request accepted from \(id)")
        }
    }
    
    func onConnect() {
        socket.on(clientEvent: .connect) { data, ack in
            print("Connected to server")
        }
    }

    func nowPlaying(song: Song, id: String, discord: Bool) {
        if socket.status == .connected {
            let songData: [String: Any] = [
                "title": song.title,
                "artist": song.artist,
                "album": song.album,
                "id": id,
                "discord": discord
            ]
            
            let payload: [String: Any] = ["nowPlaying": songData]
            
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: payload)
                if let jsonString = String(data: jsonData, encoding: .utf8) {

                }
            } catch {
                print("Error converting payload to JSON: \(error)")
            }
            
            socket.emit("nowPlaying", payload)
        } else {
            print("Socket is not connected. Cannot emit nowPlaying event.")
        }
    }

    func nowPlayingAM(song: MPMediaItem, id: String, discord: Bool) {
        if socket.status == .connected {
            let songData: [String: Any] = [
                "title": song.title,
                "artist": song.artist,
                "album": song.albumTitle,
                "id": id,
                "discord": discord
            ]
            
            let payload: [String: Any] = ["nowPlaying": songData]
            
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: payload)
                if let jsonString = String(data: jsonData, encoding: .utf8) {

                }
            } catch {
                print("Error converting payload to JSON: \(error)")
            }
            
            socket.emit("nowPlaying", payload)
        } else {
            print("Socket is not connected. Cannot emit nowPlaying event.")
        }
    }


    private func acceptF(id: String) {
        Task {
            do {
                let response = try await acceptFriend(id: id)
                snackbar = Snackbar(title: "Accept Friend", message: "\(response)")
            } catch {
                snackbar = Snackbar(title: "Accept Friend", message: "\(error.localizedDescription)")
            }
        }
    }


}
