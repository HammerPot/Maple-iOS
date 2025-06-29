// //
// //  AMPlayer.swift
// //  Maple
// //
// //  Created by Potter on 6/29/25.
// //

// import SwiftUI
// import MusicKit
// import Foundation
// import MediaPlayer
// import Combine

// class AppleMusicPlayerManager: NSObject, ObservableObject {
//     static let shared = AppleMusicPlayerManager()
    
//     private var musicPlayer = ApplicationMusicPlayer.shared
//     @Published var isPlaying = false
//     @Published var currentTime: TimeInterval = 0
//     @Published var duration: TimeInterval = 0
//     @Published var currentSong: MusicKit.Song?
//     @Published var isShuffled = false
//     @Published var repeatMode: RepeatMode = .none
//     private var timer: Timer?
//     private var nowPlayingInfo = [String: Any]()
//     private var cancellables = Set<AnyCancellable>()
    
//     public var queue: [MusicKit.Song] = []
//     private var originalQueue: [MusicKit.Song] = []
//     private var currentIndex: Int = -1
    
//     enum RepeatMode {
//         case none, one, all
//     }
    
//     private override init() {
//         super.init()
//         setupAudioSession()
//         setupRemoteTransportControls()
//         setupMusicPlayer()
//     }
    
//     private func setupAudioSession() {
//         do {
//             try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
//             try AVAudioSession.sharedInstance().setActive(true)
//         } catch {
//             print("Failed to set audio session category: \(error)")
//         }
//     }
    
//     private func setupMusicPlayer() {
//         // Monitor playback status changes using a timer instead of async stream
//         startTimer()
//     }
    
//     private func setupRemoteTransportControls() {
//         let commandCenter = MPRemoteCommandCenter.shared()
        
//         commandCenter.playCommand.addTarget { [weak self] _ in
//             guard let self = self else { return .commandFailed }
//             Task {
//                 await self.play()
//             }
//             return .success
//         }
        
//         commandCenter.pauseCommand.addTarget { [weak self] _ in
//             guard let self = self else { return .commandFailed }
//             Task {
//                 await self.pause()
//             }
//             return .success
//         }
        
//         commandCenter.nextTrackCommand.addTarget { [weak self] _ in
//             guard let self = self else { return .commandFailed }
//             Task {
//                 await self.playNext()
//             }
//             return .success
//         }
        
//         commandCenter.previousTrackCommand.addTarget { [weak self] _ in
//             guard let self = self else { return .commandFailed }
//             Task {
//                 await self.playPrevious()
//             }
//             return .success
//         }
        
//         commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
//             guard let self = self,
//                   let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
//             Task {
//                 await self.seek(to: event.positionTime)
//             }
//             return .success
//         }
//     }
    
//     func setQueue(_ songs: [MusicKit.Song], startingAt index: Int = 0) {
//         originalQueue = songs
//         queue = songs
//         currentIndex = index
//         if index < songs.count {
//             Task {
//                 await loadSong(songs[index])
//             }
//         }
//     }
    
//     func toggleShuffle() {
//         isShuffled.toggle()
//         if isShuffled {
//             queue = originalQueue.shuffled()
//         } else {
//             queue = originalQueue
//             if let currentSong = currentSong,
//                let originalIndex = originalQueue.firstIndex(of: currentSong) {
//                 currentIndex = originalIndex
//             }
//         }
//     }
    
//     func toggleRepeat() {
//         switch repeatMode {
//         case .none:
//             repeatMode = .one
//         case .one:
//             repeatMode = .all
//         case .all:
//             repeatMode = .none
//         }
//     }
    
//     private func loadSong(_ song: MusicKit.Song) async {
//         do {
//             currentSong = song
//             try await musicPlayer.queue.insert(song, position: .current)
//             updateNowPlayingInfo(song: song)
//         } catch {
//             print("Error loading song: \(error)")
//         }
//     }
    
//     private func updatePlaybackState() {
//         Task {
//             let playbackStatus = await musicPlayer.state
//             await MainActor.run {
//                 isPlaying = playbackStatus == .playing
//                 updateNowPlayingInfo(song: currentSong)
//             }
//         }
//     }
    
//     private func updateCurrentSong() {
//         Task {
//             if let currentEntry = await musicPlayer.queue.currentEntry,
//                let song = currentEntry.item as? MusicKit.Song {
//                 await MainActor.run {
//                     currentSong = song
//                     updateNowPlayingInfo(song: song)
//                 }
//             }
//         }
//     }
    
//     private func updateNowPlayingInfo(song: MusicKit.Song?) {
//         guard let song = song else { return }
        
//         var mediaArtwork: MPMediaItemArtwork?
//         if let artwork = song.artwork {
//             let size = CGSize(width: 300, height: 300)
//             mediaArtwork = MPMediaItemArtwork(boundsSize: size) { _ in
//                 return UIImage()
//             }
//         }
        
//         nowPlayingInfo = [
//             MPMediaItemPropertyTitle: song.title,
//             MPMediaItemPropertyArtist: song.artistName,
//             MPMediaItemPropertyAlbumTitle: song.albumTitle ?? "",
//             MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
//             MPMediaItemPropertyPlaybackDuration: duration,
//             MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
//         ]
        
//         if let mediaArtwork = mediaArtwork {
//             nowPlayingInfo[MPMediaItemPropertyArtwork] = mediaArtwork
//         }
        
//         MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
//     }
    
//     func play() async {
//         do {
//             try await musicPlayer.play()
//             isPlaying = true
//             startTimer()
//             if let song = currentSong {
//                 updateNowPlayingInfo(song: song)
//             }
//         } catch {
//             print("Error playing: \(error)")
//         }
//     }
    
//     func pause() async {
//         do {
//             try await musicPlayer.pause()
//             isPlaying = false
//             stopTimer()
//             if let song = currentSong {
//                 updateNowPlayingInfo(song: song)
//             }
//         } catch {
//             print("Error pausing: \(error)")
//         }
//     }
    
//     func stop() async {
//         do {
//             try await musicPlayer.stop()
//             isPlaying = false
//             currentTime = 0
//             stopTimer()
//             if let song = currentSong {
//                 updateNowPlayingInfo(song: song)
//             }
//         } catch {
//             print("Error stopping: \(error)")
//         }
//     }
    
//     func seek(to time: TimeInterval) async {
//         do {
//             musicPlayer.playbackTime = time
//             currentTime = time
//             if let song = currentSong {
//                 updateNowPlayingInfo(song: song)
//             }
//         } catch {
//             print("Error seeking: \(error)")
//         }
//     }
    
//     private func startTimer() {
//         timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
//             guard let self = self else { return }
//             Task {
//                 let position = await self.musicPlayer.playbackTime
//                 let duration = self.currentSong?.duration ?? 0
//                 await MainActor.run {
//                     self.currentTime = position
//                     self.duration = duration
//                     if let song = self.currentSong {
//                         self.updateNowPlayingInfo(song: song)
//                     }
//                 }
//             }
//         }
//     }
    
//     private func stopTimer() {
//         timer?.invalidate()
//         timer = nil
//     }
    
//     deinit {
//         stopTimer()
//     }
    
//     func playNext() async {
//         guard !queue.isEmpty else { return }
        
//         // Handle repeat one mode
//         if repeatMode == .one {
//             await seek(to: 0)
//             await play()
//             return
//         }
        
//         currentIndex = (currentIndex + 1) % queue.count
        
//         // Handle repeat all mode
//         if currentIndex == 0 && repeatMode == .all {
//             // Continue playing
//         } else if currentIndex == 0 && repeatMode == .none {
//             // Stop at end of queue
//             await stop()
//             return
//         }
        
//         let nextSong = queue[currentIndex]
//         await loadSong(nextSong)
//         await play()
//     }
    
//     func playPrevious() async {
//         guard !queue.isEmpty else { return }
        
//         // If we're more than 3 seconds into the song, restart it
//         if currentTime > 3.0 {
//             await seek(to: 0)
//             await play()
//             return
//         }
        
//         currentIndex = (currentIndex - 1 + queue.count) % queue.count
//         let previousSong = queue[currentIndex]
//         await loadSong(previousSong)
//         await play()
//     }
// }


// struct AppleMusicPlayerView: View {
//     @StateObject private var playerManager = AppleMusicPlayerManager.shared
//     @Environment(\.dismiss) private var dismiss

//     var body: some View {
//         VStack(spacing: 20) {
//             // Album Artwork
//             if let song = playerManager.currentSong,
//                let artwork = song.artwork {
//                 AsyncImage(url: artwork.url(width: 300, height: 300)) { image in
//                     image
//                         .resizable()
//                         .scaledToFit()
//                         .frame(width: 200, height: 200)
//                         .clipShape(RoundedRectangle(cornerRadius: 12))
//                 } placeholder: {
//                     RoundedRectangle(cornerRadius: 12)
//                         .fill(Color.gray.opacity(0.2))
//                         .frame(width: 200, height: 200)
//                         .overlay(
//                             Image(systemName: "music.note")
//                                 .font(.system(size: 40))
//                                 .foregroundColor(.gray)
//                         )
//                 }
//             } else {
//                 RoundedRectangle(cornerRadius: 12)
//                     .fill(Color.gray.opacity(0.2))
//                     .frame(width: 200, height: 200)
//                     .overlay(
//                         Image(systemName: "music.note")
//                             .font(.system(size: 40))
//                             .foregroundColor(.gray)
//                     )
//             }

//             // Song Info
//             VStack(spacing: 8) {
//                 Text(playerManager.currentSong?.title ?? "No Song Playing")
//                     .font(.title2)
//                     .fontWeight(.semibold)
//                     .multilineTextAlignment(.center)
                
//                 Text(playerManager.currentSong?.artistName ?? "Unknown Artist")
//                     .font(.title3)
//                     .foregroundColor(.secondary)
//                     .multilineTextAlignment(.center)
//             }
//             .padding(.horizontal)

//             // Progress Bar
//             VStack(spacing: 8) {
//                 Slider(
//                     value: Binding(
//                         get: { playerManager.currentTime },
//                         set: { newValue in
//                             Task {
//                                 await playerManager.seek(to: newValue)
//                             }
//                         }
//                     ),
//                     in: 0...max(playerManager.duration, 1)
//                 )
//                 .accentColor(.blue)

//                 HStack {
//                     Text(formatTime(playerManager.currentTime))
//                         .font(.caption)
//                         .foregroundColor(.secondary)
//                     Spacer()
//                     Text(formatTime(playerManager.duration))
//                         .font(.caption)
//                         .foregroundColor(.secondary)
//                 }
//             }
//             .padding(.horizontal)

//             // Control Buttons
//             HStack(spacing: 40) {
//                 Button(action: {
//                     Task {
//                         await playerManager.playPrevious()
//                     }
//                 }) {
//                     Image(systemName: "backward.fill")
//                         .font(.title)
//                         .foregroundColor(.primary)
//                 }

//                 Button(action: {
//                     Task {
//                         if playerManager.isPlaying {
//                             await playerManager.pause()
//                         } else {
//                             await playerManager.play()
//                         }
//                     }
//                 }) {
//                     Image(systemName: playerManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
//                         .font(.system(size: 60))
//                         .foregroundColor(.blue)
//                 }

//                 Button(action: {
//                     Task {
//                         await playerManager.playNext()
//                     }
//                 }) {
//                     Image(systemName: "forward.fill")
//                         .font(.title)
//                         .foregroundColor(.primary)
//                 }
//             }
//             .padding(.vertical, 20)

//             // Additional Controls
//             HStack(spacing: 60) {
//                 Button(action: {
//                     playerManager.toggleShuffle()
//                 }) {
//                     Image(systemName: playerManager.isShuffled ? "shuffle.circle.fill" : "shuffle")
//                         .font(.title2)
//                         .foregroundColor(playerManager.isShuffled ? .blue : .primary)
//                 }

//                 Button(action: {
//                     playerManager.toggleRepeat()
//                 }) {
//                     Image(systemName: repeatIcon)
//                         .font(.title2)
//                         .foregroundColor(playerManager.repeatMode != .none ? .blue : .primary)
//                 }
//             }
//             .padding(.vertical, 10)

//             Spacer()
//         }
//         .padding()
//         .navigationTitle("Now Playing")
//         .navigationBarTitleDisplayMode(.inline)
//         .toolbar {
//             ToolbarItem(placement: .navigationBarTrailing) {
//                 Button("Done") {
//                     dismiss()
//                 }
//             }
//         }
//     }

//     private var repeatIcon: String {
//         switch playerManager.repeatMode {
//         case .none:
//             return "repeat"
//         case .one:
//             return "repeat.1"
//         case .all:
//             return "repeat.circle.fill"
//         }
//     }

//     private func formatTime(_ time: TimeInterval) -> String {
//         let minutes = Int(time) / 60
//         let seconds = Int(time) % 60
//         return String(format: "%d:%02d", minutes, seconds)
//     }
// }