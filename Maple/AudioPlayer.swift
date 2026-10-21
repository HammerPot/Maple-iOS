import SwiftUI
import AVFoundation
import MediaPlayer
import SocketIO
import MusicKit





@MainActor
class AudioPlayerManager: NSObject, ObservableObject {
    @ObservedObject private var amPlayer = AMPlayer.shared
    static let shared = AudioPlayerManager()
    
    private var audioPlayer: AVAudioPlayer?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    private var timer: Timer?
    private var nowPlayingInfo = [String: Any]()
    @Published var currentSong: Song?
    private var isHandlingRemoteControl = false
    private var lastWebhookTrack: UUID?

    
    
    public var queue: [Song] = []
    private var currentIndex: Int = -1
    
    private override init() {
        super.init()
        setupAudioSession()
        setupRemoteTransportControls()
    }
    
    private func setupAudioSession() {
        #if !os(macOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to set audio session category: \(error)")
        }
        #endif
    }
    
    private func setupRemoteTransportControls() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            Task { @MainActor in
                self.isHandlingRemoteControl = true
                self.play()
                self.isHandlingRemoteControl = false
            }
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            Task { @MainActor in
                self.isHandlingRemoteControl = true
                self.pause()
                self.isHandlingRemoteControl = false
            }
            return .success
        }
        
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            Task { @MainActor in
                self.isHandlingRemoteControl = true
                self.playNext()
                self.isHandlingRemoteControl = false
            }
            return .success
        }
        
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            Task { @MainActor in
                self.isHandlingRemoteControl = true
                self.playPrevious()
                self.isHandlingRemoteControl = false
            }
            return .success
        }
        
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in
                self.isHandlingRemoteControl = true
                self.seek(to: position)
                self.isHandlingRemoteControl = false
            }
            return .success
        }
    }
    
    func setQueue(_ songs: [Song], startingAt index: Int = 0) {
        queue = songs
        currentIndex = index
        if songs.indices.contains(index) {
            loadSong(songs[index])
        }
    }
    
    private func loadSong(_ song: Song) {
		print("loadSong: \(song.title)")
        loadAudio(from: MapleLibrary.directory.appendingPathComponent("tracks").appendingPathComponent(song.url.lastPathComponent))
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
            
            if let song = currentSong {
                setupNowPlayingInfo(song: song)
            }
            
            audioPlayer?.delegate = self
            
            if isHandlingRemoteControl {
                play()
            }
        } catch {
            audioPlayer = nil
            isPlaying = false
            stopTimer()
            reportPlayback(claim: false)
            print("Error loading audio: \(error.localizedDescription)")
        }
    }
    
    private func setupNowPlayingInfo(song: Song) {
        currentSong = song
        
        var mediaArtwork: MPMediaItemArtwork?
        if let artwork = song.artwork {
            let artworkPath = MapleLibrary.directory.appendingPathComponent(artwork)
            if let uiImage = PlatformImage(contentsOfFile: artworkPath.path){
                mediaArtwork = MPMediaItemArtwork(boundsSize: uiImage.size) { _ in uiImage }
            }
        }
        
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
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        #endif
    }
    
    func updateNowPlayingInfo(song: Song) {
        currentSong = song
        
        var mediaArtwork: MPMediaItemArtwork?
        if let artwork = song.artwork {
            let artworkPath = MapleLibrary.directory.appendingPathComponent(artwork)
            if let uiImage = PlatformImage(contentsOfFile: artworkPath.path){
                mediaArtwork = MPMediaItemArtwork(boundsSize: uiImage.size) { _ in uiImage }
            }
        }
        
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
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        #endif
    }
    
    func play() {
        amPlayer.Stop()
        guard audioPlayer?.play() == true else {
            isPlaying = false
            reportPlayback(claim: false)
            return
        }
        isPlaying = true
        startTimer()
        if let song = currentSong {
            updateNowPlayingInfo(song: song)
            reportPlayback(claim: true)
            if lastWebhookTrack != song.id,
               let id = UserDefaults.standard.string(forKey: "savedServerID"),
               !(UserDefaults.standard.string(forKey: "webhookURL") ?? "").isEmpty {
                lastWebhookTrack = song.id
                Task {
                    do { _ = try await sendWebhook(song: song, serverID: id) }
                    catch { print("Unable to send webhook: \(error.localizedDescription)") }
                }
            }
        }
    }

    func playbackSnapshot() -> MaplePlaybackSnapshot? {
        guard let song = currentSong else { return nil }
        return MaplePlaybackSnapshot(trackID: song.id.uuidString, source: "iOS", title: song.title,
                                     artist: song.artist, album: song.album, playing: audioPlayer?.isPlaying == true,
                                     position: audioPlayer?.currentTime ?? 0, duration: audioPlayer?.duration ?? 0,
                                     playbackRate: Double(audioPlayer?.rate ?? 1))
    }

    private func reportPlayback(claim: Bool) {
        let artwork = currentSong?.artwork.flatMap {
            PlatformImage(contentsOfFile: MapleLibrary.directory.appendingPathComponent($0).path)?.jpegData(compressionQuality: 0.85)
        } ?? PlatformImage(named: "Maple")?.jpegData(compressionQuality: 0.85)
        AppSocketManager.shared.updatePlayback({ [weak self] in self?.playbackSnapshot() }, artwork: artwork, claim: claim)
    }

    func pause() {
        print("Pause called - current audio player exists: \(audioPlayer != nil)")
        audioPlayer?.pause()
        isPlaying = false
        stopTimer()
        reportPlayback(claim: false)
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
        reportPlayback(claim: false)
        if let song = currentSong {
            updateNowPlayingInfo(song: song)
        }
    }
    
    func seek(to time: TimeInterval) {
        audioPlayer?.currentTime = time
        currentTime = time
        reportPlayback(claim: isPlaying)
        if let song = currentSong {
            updateNowPlayingInfo(song: song)
        }
    }
    
    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.audioPlayer else { return }
                self.currentTime = player.currentTime
                if let song = self.currentSong { self.updateNowPlayingInfo(song: song) }
            }
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    deinit {
        timer?.invalidate()
    }
    
    func clearQueue() {
        stop()
        queue = []
        currentIndex = -1
        currentSong = nil
        audioPlayer = nil
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
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


extension AudioPlayerManager: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.audioPlayer.map(ObjectIdentifier.init) == playerID else { return }
            self.isPlaying = false
            self.reportPlayback(claim: false)
            if flag { self.playNext() }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.audioPlayer.map(ObjectIdentifier.init) == playerID else { return }
            self.isPlaying = false
            self.stopTimer()
            self.reportPlayback(claim: false)
        }
    }
}

struct AudioPlayerView: View {
    let song: Song
    let allSongs: [Song]
    @State private var hasInitializedQueue = false

    var body: some View {
        LocalPlayerControls()
            .onAppear {
                guard !hasInitializedQueue,
                      let index = allSongs.firstIndex(where: { $0.id == song.id }) else { return }
                hasInitializedQueue = true
                AudioPlayerManager.shared.setQueue(allSongs, startingAt: index)
            }
    }
}

struct MediaPlayerView: View {
    let song: Song
    let allSongs: [Song]

    var body: some View { LocalPlayerControls() }
}
