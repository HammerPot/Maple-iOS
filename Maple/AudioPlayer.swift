import SwiftUI
import AVFoundation
import MediaPlayer
import SocketIO





class AudioPlayerManager: NSObject, ObservableObject {
    static let shared = AudioPlayerManager()
    
    private var audioPlayer: AVAudioPlayer?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    private var timer: Timer?
    private var nowPlayingInfo = [String: Any]()
    @Published var currentSong: Song?
    private var isHandlingRemoteControl = false
    @State private var serverID: String = ""

    
    
    // Queue management
    private var queue: [Song] = []
    private var currentIndex: Int = -1
    
    private override init() {
        super.init()
        setupAudioSession()
        setupRemoteTransportControls()
    }
    
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to set audio session category: \(error)")
        }
    }
    
    private func setupRemoteTransportControls() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Add handler for play command
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.isHandlingRemoteControl = true
            self.play()
            self.isHandlingRemoteControl = false
            return .success
        }
        
        // Add handler for pause command
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.isHandlingRemoteControl = true
            self.pause()
            self.isHandlingRemoteControl = false
            return .success
        }
        
        // Add handler for next track command
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.isHandlingRemoteControl = true
            self.playNext()
            self.isHandlingRemoteControl = false
            return .success
        }
        
        // Add handler for previous track command
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.isHandlingRemoteControl = true
            self.playPrevious()
            self.isHandlingRemoteControl = false
            return .success
        }
        
        // Add handler for seek command
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.isHandlingRemoteControl = true
            self.seek(to: event.positionTime)
            self.isHandlingRemoteControl = false
            return .success
        }
    }
    
    func setQueue(_ songs: [Song], startingAt index: Int = 0) {
        queue = songs
        currentIndex = index
        if index < songs.count {
            loadSong(songs[index])
        }
    }
    
    private func loadSong(_ song: Song) {
		print("loadSong: \(song.title)")
        loadAudio(from: song.url)
        updateNowPlayingInfo(song: song)
    }
    
    func loadAudio(from url: URL) {
        do {
            print("Loading audio from URL: \(url)")
            print("Current audio player state - isPlaying: \(isPlaying), currentTime: \(currentTime)")
            
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.prepareToPlay()
            duration = audioPlayer?.duration ?? 0
            
            print("New audio player created - duration: \(duration)")
            
            // Setup now playing info
            if let song = currentSong {
                setupNowPlayingInfo(song: song)
            }
            
            // Set up completion handler
            audioPlayer?.delegate = self
            
            // If we're handling a remote control event, automatically start playing
            if isHandlingRemoteControl {
                play()
            }
        } catch {
            print("Error loading audio: \(error.localizedDescription)")
        }
    }
    
    private func setupNowPlayingInfo(song: Song) {
        currentSong = song
        
        // Create artwork
        var mediaArtwork: MPMediaItemArtwork?
        if let artwork = song.artwork {
            let artworkPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(artwork)
            if let uiImage = UIImage(contentsOfFile: artworkPath.path){
                mediaArtwork = MPMediaItemArtwork(boundsSize: uiImage.size) { _ in uiImage }
            }
        }
        
        // Setup now playing info
        nowPlayingInfo = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyAlbumTitle: song.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        
        if let mediaArtwork = mediaArtwork {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = mediaArtwork
        }
        
        // Update the now playing info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    func updateNowPlayingInfo(song: Song) {
        currentSong = song
        
        // Create artwork
        var mediaArtwork: MPMediaItemArtwork?
        if let artwork = song.artwork {
            let artworkPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(artwork)
            if let uiImage = UIImage(contentsOfFile: artworkPath.path){
                mediaArtwork = MPMediaItemArtwork(boundsSize: uiImage.size) { _ in uiImage }
            }
        }
        
        // Setup now playing info
        nowPlayingInfo = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyAlbumTitle: song.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        
        if let mediaArtwork = mediaArtwork {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = mediaArtwork
        }
        
        // Update the now playing info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    func play() {
        print("Play called - current audio player exists: \(audioPlayer != nil)")
        audioPlayer?.play()
        isPlaying = true
        startTimer()
        if let song = currentSong {
            updateNowPlayingInfo(song: song)

            

            if let savedServerID = UserDefaults.standard.string(forKey: "savedServerID") {
                if let _artwork = song.artwork {
                    let artworkPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(_artwork)
                    if let artwork = UIImage(contentsOfFile: artworkPath.path)?.pngData(){
                        Task { 
                            do {
                                try await setAlbumArt(serverID: savedServerID, albumArt: artwork)
                            } catch {
                                print("Error setting album art: \(error)")
                            }
                            do {
                                try await sendWebhook(song: song, serverID: savedServerID)
                            } catch {
                                print("Error sending webhook: \(error)")
                            }
                        }
                    }
                }
                else {
                    print("No artwork found for song: \(song.title)")
                    Task {
                        do {
                            try await setAlbumArt(serverID: savedServerID, albumArt: UIImage(named: "Maple")!.pngData()!)
                        } catch {
                            print("Error setting album art: \(error)")
                        }
                        do {
                            try await sendWebhook(song: song, serverID: savedServerID)
                        } catch {
                            print("Error sending webhook: \(error)")
                        }
                    }
                }
                AppSocketManager.shared.nowPlaying(song: song, id: savedServerID, discord: true)
            }
            else {
                AppSocketManager.shared.nowPlaying(song: song, id: serverID, discord: true)
            }
        }
        
    }
    
    func pause() {
        print("Pause called - current audio player exists: \(audioPlayer != nil)")
        audioPlayer?.pause()
        isPlaying = false
        stopTimer()
        if let song = currentSong {
            updateNowPlayingInfo(song: song)
        }
    }
    
    func stop() {
        print("Stop called - current audio player exists: \(audioPlayer != nil)")
        audioPlayer?.stop()
        audioPlayer?.currentTime = 0
        isPlaying = false
        currentTime = 0
        stopTimer()
        if let song = currentSong {
            updateNowPlayingInfo(song: song)
        }
    }
    
    func seek(to time: TimeInterval) {
        audioPlayer?.currentTime = time
        currentTime = time
        if let song = currentSong {
            updateNowPlayingInfo(song: song)
        }
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.audioPlayer else { return }
            self.currentTime = player.currentTime
            if let song = self.currentSong {
                self.updateNowPlayingInfo(song: song)
            }
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    deinit {
        stopTimer()
    }
    
    func playNext() {
        guard !queue.isEmpty else { return }
        print("playNext")
        currentIndex = (currentIndex + 1) % queue.count
        let nextSong = queue[currentIndex]
        print("Loading next song: \(nextSong.title)")
        loadSong(nextSong)
        play()
    }
    
    func playPrevious() {
        guard !queue.isEmpty else { return }
        print("playPrevious")
        currentIndex = (currentIndex - 1 + queue.count) % queue.count
        let previousSong = queue[currentIndex]
        print("Loading previous song: \(previousSong.title)")
        loadSong(previousSong)
        play()
    }
}

// Add AVAudioPlayerDelegate extension
extension AudioPlayerManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if flag {
            playNext()
        }
    }
}

struct AudioPlayerView: View {
    @ObservedObject private var audioManager = AudioPlayerManager.shared
    let song: Song
    let allSongs: [Song]
    @State private var hasInitializedQueue = false
    
    init(song: Song, allSongs: [Song]) {
        self.song = song
        self.allSongs = allSongs
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // Album Art
            if let artworkData = audioManager.currentSong?.artwork {
                let artworkPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(artworkData)
                if let uiImage = UIImage(contentsOfFile: artworkPath.path){
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 160, height: 160) // Adjust size as needed
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding()
                }
            } else {
                // Placeholder image if no artwork is available
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

            // Song Info
            VStack(spacing: 8) {
                Text(audioManager.currentSong?.title ?? song.title)
                    .font(.headline)
                Text(audioManager.currentSong?.artist ?? song.artist)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            // Playback Controls
            HStack(spacing: 30) {
                Button(action: {
                    audioManager.playPrevious()
                }) {
                    Image(systemName: "backward.circle.fill")
                        .font(.system(size: 44))
                }
                
                Button(action: {
                    if audioManager.isPlaying {
                        audioManager.pause()
                    } else {
                        audioManager.play()
                    }
                }) {
                    Image(systemName: audioManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                
                Button(action: {
                    audioManager.playNext()
                }) {
                    Image(systemName: "forward.circle.fill")
                        .font(.system(size: 44))
                }
            }
            
            // Progress Bar
            VStack {
                Slider(value: Binding(
                    get: { audioManager.currentTime },
                    set: { audioManager.seek(to: $0) }
                ), in: 0...audioManager.duration)
                
                HStack {
                    Text(formatTime(audioManager.currentTime))
                        .font(.caption)
                    Spacer()
                    Text(formatTime(audioManager.duration))
                        .font(.caption)
                }
            }
        }
        .padding()
        .onAppear {
            // Only set up the queue if we haven't done so for this song
            if !hasInitializedQueue {
                print("allSongs titles: \(allSongs.map { $0.title })")
                print("song: \(song.title)")
                print("\(allSongs.firstIndex(where: { $0.url == song.url }))")
                if let index = allSongs.firstIndex(where: { $0.url == song.url }) {
                    audioManager.setQueue(allSongs, startingAt: index)
                    hasInitializedQueue = true
                }
            }
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    // AudioPlayerView(
    //     song: Song(
    //         url: URL(fileURLWithPath: ""),
    //         title: "Sample Song",
    //         artist: "Sample Artist",
    //         album: "Sample Album",
    //         artwork: nil,
    //         trackNumber: 1,
    //         discNumber: 1
    //     ),
    //     allSongs: []
    // )
} 