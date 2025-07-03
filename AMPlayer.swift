import Foundation
import MusicKit
import SwiftUI
import MediaPlayer


@MainActor
class AMPlayer: ObservableObject {
    static let shared = AMPlayer()




    init() {
        print("AMPlayer init")
        setupNotifications()
        getState()
        getCurrentTime()
        getNowPlayingItem()
    }
    
    private let player = MPMusicPlayerController.systemMusicPlayer
    
    private func setupNotifications() {
        // Listen for playback state changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playbackStateDidChange),
            name: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: player
        )
        
        // Listen for now playing item changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(nowPlayingItemDidChange),
            name: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: player
        )
        
        // Start observing notifications
        player.beginGeneratingPlaybackNotifications()
    }
    
    @objc private func playbackStateDidChange() {
        print("Playback state changed: \(player.playbackState)")
        print("PBSC: player.nowPlayingItem: \(player.nowPlayingItem?.title)")
        if player.playbackState.rawValue == 1 {
            print("Playing")
            if let mapleArt = UIImage(named: "Maple")?.pngData() {
                print("Setting album art")
                Task {
                    do {
                        let response = try await setAlbumArt(serverID: UserDefaults.standard.string(forKey: "savedServerID") ?? "", albumArt: player.nowPlayingItem?.artwork?.image(at: CGSize(width: 800, height: 800))?.pngData() ?? mapleArt)
                    } catch {
                        print("Error setting album art: \(error)")
                    }
                    AppSocketManager.shared.nowPlayingAM(song: player.nowPlayingItem!, id: UserDefaults.standard.string(forKey: "savedServerID") ?? "", discord: UserDefaults.standard.bool(forKey: "discord"))
                }
            }
        }
    }
    
    @objc private func nowPlayingItemDidChange() {
        print("Now playing item changed")
        print("NPI: player.nowPlayingItem: \(player.nowPlayingItem?.title)")
        if let nowPlayingItem = player.nowPlayingItem {

        }
    }
    
    deinit {
        // Stop observing notifications
        player.endGeneratingPlaybackNotifications()
        NotificationCenter.default.removeObserver(self)
    }

    func getState() -> MPMusicPlaybackState {
        print("player.playbackState: \(player.playbackState)")
        return player.playbackState
    }

    func getCurrentTime() -> TimeInterval {
        print("player.currentPlaybackTime: \(player.currentPlaybackTime)")
        return player.currentPlaybackTime
    }
    
    func getNowPlayingItem() -> MPMediaItem? {
        if let nowPlayingItem = player.nowPlayingItem {
        print("nowPlayingItem.title: \(nowPlayingItem.title)")
        print("nowPlayingItem.artist: \(nowPlayingItem.artist)")
        print("nowPlayingItem.albumTitle: \(nowPlayingItem.albumTitle)")
        print("nowPlayingItem.albumArtist: \(nowPlayingItem.albumArtist)")
        print("nowPlayingItem.genre: \(nowPlayingItem.genre)")
        print("nowPlayingItem.composer: \(nowPlayingItem.composer)")
        print("nowPlayingItem.playbackDuration: \(nowPlayingItem.playbackDuration)")
        print("nowPlayingItem.albumTrackNumber: \(nowPlayingItem.albumTrackNumber)")
        print("nowPlayingItem.albumTrackCount: \(nowPlayingItem.albumTrackCount)")
        print("nowPlayingItem.discNumber: \(nowPlayingItem.discNumber)")
        print("nowPlayingItem.discCount: \(nowPlayingItem.discCount)")
        print("nowPlayingItem.releaseDate: \(nowPlayingItem.releaseDate)")
        print("nowPlayingItem.beatsPerMinute: \(nowPlayingItem.beatsPerMinute)")
        print("nowPlayingItem.comments: \(nowPlayingItem.comments)")
        print("nowPlayingItem.rating: \(nowPlayingItem.rating)")
        print("nowPlayingItem.assetURL: \(nowPlayingItem.assetURL?.absoluteString)")
        print("nowPlayingItem.isExplicitItem: \(nowPlayingItem.isExplicitItem)")
        print("nowPlayingItem.isCloudItem: \(nowPlayingItem.isCloudItem)")
        print("nowPlayingItem.hasProtectedAsset: \(nowPlayingItem.hasProtectedAsset)")
        print("nowPlayingItem.persistentID: \(nowPlayingItem.persistentID)")
        print("nowPlayingItem.mediaType: \(nowPlayingItem.mediaType)")
        print("nowPlayingItem.lastPlayedDate: \(nowPlayingItem.lastPlayedDate)")
        print("nowPlayingItem.userGrouping: \(nowPlayingItem.userGrouping ?? "nil")")
        print("nowPlayingItem.bookmarkTime: \(nowPlayingItem.bookmarkTime)")
        print("nowPlayingItem.skipCount: \(nowPlayingItem.skipCount)")
        print("nowPlayingItem.playCount: \(nowPlayingItem.playCount)")
        print("nowPlayingItem.dateAdded: \(nowPlayingItem.dateAdded)")
        print("nowPlayingItem.lyrics: \(nowPlayingItem.lyrics)")
        } else {
            print("player.nowPlayingItem: No item")
        }
        return player.nowPlayingItem
    }

    
}
