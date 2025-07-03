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

class AppSocketManager: ObservableObject {
    static let shared = AppSocketManager()
    let enabled = UserDefaults.standard.bool(forKey: "socketIO")

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
}
