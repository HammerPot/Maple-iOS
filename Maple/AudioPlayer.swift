import SwiftUI
import AVFoundation
import MediaPlayer

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
        updateNowPlayingInfo(
            title: song.title,
            artist: song.artist,
            album: song.album,
            artwork: song.artwork
        )
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
                setupNowPlayingInfo(title: song.title, artist: song.artist, album: song.album, artwork: song.artwork)
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
    
    private func setupNowPlayingInfo(title: String, artist: String, album: String, artwork: UIImage?) {
        currentSong = Song(url: audioPlayer?.url ?? URL(fileURLWithPath: ""), title: title, artist: artist, album: album, artwork: artwork, trackNumber: 1, discNumber: 1)
        
        // Create artwork
        var mediaArtwork: MPMediaItemArtwork?
        if let artwork = artwork {
            mediaArtwork = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        
        // Setup now playing info
        nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: album,
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
    
    func updateNowPlayingInfo(title: String, artist: String, album: String, artwork: UIImage?) {
        currentSong = Song(url: audioPlayer?.url ?? URL(fileURLWithPath: ""), title: title, artist: artist, album: album, artwork: artwork, trackNumber: 1, discNumber: 1)
        
        // Create artwork
        var mediaArtwork: MPMediaItemArtwork?
        if let artwork = artwork {
            mediaArtwork = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        
        // Setup now playing info
        nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: album,
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
            updateNowPlayingInfo(title: song.title, artist: song.artist, album: song.album, artwork: song.artwork)
        }
    }
    
    func pause() {
        print("Pause called - current audio player exists: \(audioPlayer != nil)")
        audioPlayer?.pause()
        isPlaying = false
        stopTimer()
        if let song = currentSong {
            updateNowPlayingInfo(title: song.title, artist: song.artist, album: song.album, artwork: song.artwork)
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
            updateNowPlayingInfo(title: song.title, artist: song.artist, album: song.album, artwork: song.artwork)
        }
    }
    
    func seek(to time: TimeInterval) {
        audioPlayer?.currentTime = time
        currentTime = time
        if let song = currentSong {
            updateNowPlayingInfo(title: song.title, artist: song.artist, album: song.album, artwork: song.artwork)
        }
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.audioPlayer else { return }
            self.currentTime = player.currentTime
            if let song = self.currentSong {
                self.updateNowPlayingInfo(title: song.title, artist: song.artist, album: song.album, artwork: song.artwork)
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
    AudioPlayerView(
        song: Song(
            url: URL(fileURLWithPath: ""),
            title: "Sample Song",
            artist: "Sample Artist",
            album: "Sample Album",
            artwork: nil,
            trackNumber: 1,
            discNumber: 1
        ),
        allSongs: []
    )
} 