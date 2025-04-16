import SwiftUI
import AVFoundation
import MediaPlayer

class AudioPlayerManager: ObservableObject {
    private var audioPlayer: AVAudioPlayer?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    private var timer: Timer?
    private var nowPlayingInfo = [String: Any]()
    var currentSong: Song?
    private var isHandlingRemoteControl = false
    
    init() {
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
    
    func loadAudio(from url: URL) {
        // Don't load new audio if we're handling a remote control event
        guard !isHandlingRemoteControl else { return }
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.prepareToPlay()
            duration = audioPlayer?.duration ?? 0
            
            // Setup now playing info
            if let song = currentSong {
                setupNowPlayingInfo(title: song.title, artist: song.artist, album: song.album, artwork: song.artwork)
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
        audioPlayer?.play()
        isPlaying = true
        startTimer()
        if let song = currentSong {
            updateNowPlayingInfo(title: song.title, artist: song.artist, album: song.album, artwork: song.artwork)
        }
    }
    
    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopTimer()
        if let song = currentSong {
            updateNowPlayingInfo(title: song.title, artist: song.artist, album: song.album, artwork: song.artwork)
        }
    }
    
    func stop() {
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
}

struct AudioPlayerView: View {
    @StateObject private var audioManager = AudioPlayerManager()
    let song: Song
    
    init(song: Song) {
        self.song = song
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // Song Info
            VStack(spacing: 8) {
                Text(song.title)
                    .font(.headline)
                Text(song.artist)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            // Playback Controls
            HStack(spacing: 30) {
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
            // Only load audio if it's not already loaded
            if audioManager.currentSong?.url == nil {
                audioManager.loadAudio(from: song.url)
                audioManager.updateNowPlayingInfo(
                    title: song.title,
                    artist: song.artist,
                    album: song.album,
                    artwork: song.artwork
                )
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
    AudioPlayerView(song: Song(
        url: URL(fileURLWithPath: ""),
        title: "Sample Song",
        artist: "Sample Artist",
        album: "Sample Album",
        artwork: nil,
        trackNumber: 1,
        discNumber: 1
    ))
} 