import Foundation
import MusicKit
import SwiftUI
import MediaPlayer
import MusadoraKit



@MainActor
class AMPlayer: ObservableObject {
    static let shared = AMPlayer()
    @Published var hasInitializedQueue = false
    @Published var albumArt: UIImage?
    @Published var initialized = false
    @Published var isPlaying = false



    init() {
        setupNotifications()
        getState()
        getCurrentTime()
        getNowPlayingItem()
    }
    
    let player = MPMusicPlayerController.systemMusicPlayer
    
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
        if player.playbackState == .playing {
            initialized = true
            isPlaying = true
        }
        else if player.playbackState == .stopped {
            initialized = false
            isPlaying = false
        }
        else if player.playbackState == .paused {
            // initialized = true
            isPlaying = false
        }
        else if player.playbackState == .interrupted {
            initialized = false
            isPlaying = false
        }
        else {
            initialized = false
            isPlaying = false
        }
        albumArt = UIImage(data: player.nowPlayingItem?.artwork?.image(at: CGSize(width: 800, height: 800))?.pngData() ?? UIImage(named: "Maple")?.pngData() ?? Data())
        if player.playbackState.rawValue == 1 {
            if let mapleArt = UIImage(named: "Maple")?.pngData() {
                Task {
                    do {
                        let response = try await setAlbumArt(serverID: UserDefaults.standard.string(forKey: "savedServerID") ?? "", albumArt: player.nowPlayingItem?.artwork?.image(at: CGSize(width: 800, height: 800))?.pngData() ?? mapleArt)
                    } catch {
                    }
                    AppSocketManager.shared.nowPlayingAM(song: player.nowPlayingItem!, id: UserDefaults.standard.string(forKey: "savedServerID") ?? "", discord: UserDefaults.standard.bool(forKey: "discord"))
                }
            }
        }
    }
    
    @objc private func nowPlayingItemDidChange() {
        if let nowPlayingItem = player.nowPlayingItem {
            if let currentEntry = SystemMusicPlayer.shared.queue.currentEntry,
               case .song(let song) = currentEntry.item {
                let title = song.title
                let artist = song.artistName
                let duration = song.duration
                let albumTitle = song.albumTitle
            }
        }
    }
    
    deinit {
        // Stop observing notifications
        player.endGeneratingPlaybackNotifications()
        NotificationCenter.default.removeObserver(self)
    }

    func getState() -> MPMusicPlaybackState {
        return player.playbackState
    }

    func getCurrentTime() -> TimeInterval {
        return player.currentPlaybackTime
    }
    
    func getNowPlayingItem() -> MPMediaItem? {
        if let nowPlayingItem = player.nowPlayingItem {
        } else {
        }
        return player.nowPlayingItem
    }

    func queue(song: MusicKit.Track, allSongs: [MusicKit.Track]) {
        print("func queue called")
        if let index = allSongs.firstIndex(where: { $0.url == song.url }) {
            print("index: \(index)")
            let reorderedSongs = Array(allSongs[index...] + allSongs[..<index])
            print("reorderedSongs: \(reorderedSongs[0].title)")
            let songIds = reorderedSongs.map { $0.title }
            print("songIds: \(songIds[0])")
            let query = MPMediaQuery.songs()
            print("query is songs moment")
            query.addFilterPredicate(
                MPMediaPropertyPredicate(
                    value: songIds,
                    forProperty: MPMediaItemPropertyTitle,
                    comparisonType: .equalTo
                )
            )
            print("query.items?.count: \(query.items?.count ?? 0)")
            let songsCollection = MPMediaItemCollection(items: query.items ?? [])
            print("songsCollection count: \(songsCollection.items.count ?? 0)")
            player.setQueue(with: songsCollection)
            print("queue set")
        }
    }

    func queue2(song: MusicKit.Track, allSongs: [MusicKit.Track], type: String) {
        if type == "song" {
            Task {
                do {
                    // Insert at head to prioritize this song
                    try await SystemMusicPlayer.shared.stop()
                    try await SystemMusicPlayer.shared.queue.insert([song], position: .afterCurrentEntry)
                    try await SystemMusicPlayer.shared.skipToNextEntry()
                    try await SystemMusicPlayer.shared.play()
                    hasInitializedQueue = true
                } catch {
                    print("Error: \(error)")
                }
            }
        }
        else if type == "album" {
            // Make a new array from allSongs that starts with song, removing any items before song
            // if let index = allSongs.firstIndex(where: { $0.id == song.id }) {
                // let reorderedSongs = Array(allSongs[index...])
                // Use reorderedSongs for queueing
            Task {
                do {
                    try await SystemMusicPlayer.shared.stop()
                    try await SystemMusicPlayer.shared.queue.insert(allSongs, position: .afterCurrentEntry)
                    try await SystemMusicPlayer.shared.skipToNextEntry()
                    
                    // Wait for queue to be ready with boolean polling
                    var queueReady = false
                    var attempts = 0
                    let maxAttempts = 500 // 5 seconds maximum wait time
                    
                    while !queueReady && attempts < maxAttempts {
                        if let currentEntry = SystemMusicPlayer.shared.queue.currentEntry,
                           case .song(let currentSong) = currentEntry.item,
                           let firstSong = allSongs.first,
                           currentSong.title == firstSong.title {
                            queueReady = true
                        } else {
                            attempts += 1
                            try await Task.sleep(nanoseconds: 10_000_000) // 10ms between checks
                        }
                    }
                    
                    if !queueReady {
                        print("Queue failed to initialize after 5 seconds")
                        return
                    }
                    
                    // 5 seconds maximum wait time



                    for i in 0..<allSongs.count {
                        var placementReady = false
                        var placementAttempts = 0
                        let placementMaxAttempts = 200 // 2 seconds maximum wait time



                        if let currentEntry = SystemMusicPlayer.shared.queue.currentEntry,
                        case .song(let songCE) = currentEntry.item {
                            print("songCE.title: \(songCE.title)")
                            print("song.title: \(song.title)")
                            if songCE.title != song.title {
                                print("skipping to next entry")
                                try await SystemMusicPlayer.shared.skipToNextEntry()
                            }
                            else if songCE.title == song.title {
                                print("song found")
                                break
                            }
                            if i == allSongs.count - 1 {
                                print("song not found")
                                break
                            }
                        }
                        
                        while !placementReady && placementAttempts < placementMaxAttempts {
                            let curSong = allSongs[i+1]
                            if let currentEntry = SystemMusicPlayer.shared.queue.currentEntry,
                            case .song(let songCE) = currentEntry.item,
                            curSong.title == songCE.title {
                                placementReady = true
                            }
                            else {
                                placementAttempts += 1
                                try await Task.sleep(nanoseconds: 10_000_000) // 10ms between checks
                            }
                        }
                    }
                
                    
                    
                    try await SystemMusicPlayer.shared.play()
                    hasInitializedQueue = true
                } catch {
                    print("Error: \(error)")
                }
            }
        }
        else if type == "playlist" {
            Task {
                do {
                    try await SystemMusicPlayer.shared.stop()
                    try await SystemMusicPlayer.shared.queue.insert(allSongs, position: .afterCurrentEntry)
                    try await SystemMusicPlayer.shared.skipToNextEntry()
                    
                    // Wait for queue to be ready with boolean polling
                    var queueReady = false
                    var attempts = 0
                    let maxAttempts = 500 // 5 seconds maximum wait time
                    
                    while !queueReady && attempts < maxAttempts {
                        if let currentEntry = SystemMusicPlayer.shared.queue.currentEntry,
                           case .song(let currentSong) = currentEntry.item,
                           let firstSong = allSongs.first,
                           currentSong.title == firstSong.title {
                            queueReady = true
                        } else {
                            attempts += 1
                            try await Task.sleep(nanoseconds: 10_000_000) // 10ms between checks
                        }
                    }
                    
                    if !queueReady {
                        print("Queue failed to initialize after 5 seconds")
                        return
                    }
                    
                    // 5 seconds maximum wait time



                    for i in 0..<allSongs.count {
                        var placementReady = false
                        var placementAttempts = 0
                        let placementMaxAttempts = 200 // 2 seconds maximum wait time



                        if let currentEntry = SystemMusicPlayer.shared.queue.currentEntry,
                        case .song(let songCE) = currentEntry.item {
                            print("songCE.title: \(songCE.title)")
                            print("song.title: \(song.title)")
                            if songCE.title != song.title {
                                print("skipping to next entry")
                                try await SystemMusicPlayer.shared.skipToNextEntry()
                            }
                            else if songCE.title == song.title {
                                print("song found")
                                break
                            }
                            if i == allSongs.count - 1 {
                                print("song not found")
                                break
                            }
                        }
                        
                        while !placementReady && placementAttempts < placementMaxAttempts {
                            let curSong = allSongs[i+1]
                            if let currentEntry = SystemMusicPlayer.shared.queue.currentEntry,
                            case .song(let songCE) = currentEntry.item,
                            curSong.title == songCE.title {
                                placementReady = true
                            }
                            else {
                                placementAttempts += 1
                                try await Task.sleep(nanoseconds: 10_000_000) // 10ms between checks
                            }
                        }
                    }
                
                    
                    
                    try await SystemMusicPlayer.shared.play()
                    hasInitializedQueue = true
                } catch {
                    print("Error: \(error)")
                }
            }
        }
    }

    func Stop() {
        initialized = false
        if player.playbackState == .playing {
            SystemMusicPlayer.shared.stop()
        }
    }

    func skipToNextEntry(songs: [MusicKit.Track]) async throws -> Bool {
        try await SystemMusicPlayer.shared.queue.insert(songs, position: .afterCurrentEntry)
        return true
    }
}



struct AMPlayerView: View {
    @StateObject private var player = AMPlayer.shared
    let song: MusicKit.Track
    let allSongs: [MusicKit.Track]
    let type: String
    @State private var hasInitializedQueue = false
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0

    init(song: MusicKit.Track, allSongs: [MusicKit.Track], type: String) {
        self.song = song
        self.allSongs = allSongs
        self.type = type
    }

    var body: some View {
        VStack(spacing: 20) {
            // Album artwork
            if let artwork = player.albumArt {
                Image(uiImage: artwork)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 160, height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding()

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

            // Song info
            VStack(spacing: 8) {
                if let currentEntry = SystemMusicPlayer.shared.queue.currentEntry,
                   case .song(let song) = currentEntry.item {
                    Text(song.title)
                        .font(.headline)
                    Text(song.artistName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    Text("No song playing")
                        .font(.headline)
                    Text("Unknown artist")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            
            // Playback controls
            HStack(spacing: 30) {
                Button(action: {
                    Task {
                        try? await SystemMusicPlayer.shared.skipToPreviousEntry()
                    }
                }) {
                    Image(systemName: "backward.circle.fill")
                        .font(.system(size: 44))
                }
                
                Button(action: {
                    Task {
                        if isPlaying {
                            SystemMusicPlayer.shared.pause()
                        } else {
                            try? await SystemMusicPlayer.shared.play()
                        }
                    }
                }) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                
                Button(action: {
                    Task {
                        try? await SystemMusicPlayer.shared.skipToNextEntry()
                    }
                }) {
                    Image(systemName: "forward.circle.fill")
                        .font(.system(size: 44))
                }
            }
            
            // Progress slider
            VStack {
                Slider(value: Binding(
                    get: { currentTime },
                    set: { newTime in
                        SystemMusicPlayer.shared.playbackTime = newTime
                    }
                ), in: 0...duration)
                
                HStack {
                    Text(formatTime(currentTime))
                        .font(.caption)
                    Spacer()
                    Text(formatTime(duration))
                        .font(.caption)
                }
            }
        }
        .padding()
        .onAppear {
            if !hasInitializedQueue {
                Task {
                    player.queue2(song: song, allSongs: allSongs, type: type)
                    hasInitializedQueue = true
                }
            }
            updatePlaybackState()
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            updatePlaybackState()
        }
    }
    
    private func updatePlaybackState() {
        isPlaying = SystemMusicPlayer.shared.state.playbackStatus == .playing
        currentTime = SystemMusicPlayer.shared.playbackTime
        
        // Extract the Song object from the enum case
        if let currentEntry = SystemMusicPlayer.shared.queue.currentEntry,
           case .song(let song) = currentEntry.item {
            duration = song.duration ?? 0
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct AMPlayerView2: View {
    @StateObject private var player = AMPlayer.shared
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0

    var body: some View {
        VStack(spacing: 20) {
            // Album artwork
            if let artwork = player.albumArt {
                Image(uiImage: artwork)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 160, height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding()

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

            // Song info
            VStack(spacing: 8) {
                if let currentEntry = SystemMusicPlayer.shared.queue.currentEntry,
                   case .song(let song) = currentEntry.item {
                    Text(song.title)
                        .font(.headline)
                    Text(song.artistName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    Text("No song playing")
                        .font(.headline)
                    Text("Unknown artist")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            
            // Playback controls
            HStack(spacing: 30) {
                Button(action: {
                    Task {
                        try? await SystemMusicPlayer.shared.skipToPreviousEntry()
                    }
                }) {
                    Image(systemName: "backward.circle.fill")
                        .font(.system(size: 44))
                }
                
                Button(action: {
                    Task {
                        if isPlaying {
                            SystemMusicPlayer.shared.pause()
                        } else {
                            try? await SystemMusicPlayer.shared.play()
                        }
                    }
                }) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                
                Button(action: {
                    Task {
                        try? await SystemMusicPlayer.shared.skipToNextEntry()
                    }
                }) {
                    Image(systemName: "forward.circle.fill")
                        .font(.system(size: 44))
                }
            }
            
            // Progress slider
            VStack {
                Slider(value: Binding(
                    get: { currentTime },
                    set: { newTime in
                        SystemMusicPlayer.shared.playbackTime = newTime
                    }
                ), in: 0...duration)
                
                HStack {
                    Text(formatTime(currentTime))
                        .font(.caption)
                    Spacer()
                    Text(formatTime(duration))
                        .font(.caption)
                }
            }
        }
        .padding()
        .onAppear {
            updatePlaybackState()
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            updatePlaybackState()
        }
    }
    
    private func updatePlaybackState() {
        isPlaying = SystemMusicPlayer.shared.state.playbackStatus == .playing
        currentTime = SystemMusicPlayer.shared.playbackTime
        
        // Extract the Song object from the enum case
        if let currentEntry = SystemMusicPlayer.shared.queue.currentEntry,
           case .song(let song) = currentEntry.item {
            duration = song.duration ?? 0
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}