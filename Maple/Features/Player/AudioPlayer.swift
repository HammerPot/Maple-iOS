import SwiftUI
import AVFoundation
import MediaPlayer
import MusicKit





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
    weak var playbackReporter: PlaybackReporter?
    weak var libraryStore: LibraryStore?
    private var startedTrackID: UUID?
    private var lastListeningSample: TimeInterval?
    private var mapleRPC = UserDefaults.standard.bool(forKey: "mapleRPC")
    private var rpcTask = false

    
    
    public var queue: [Song] = []
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
        
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.isHandlingRemoteControl = true
            self.play()
            self.isHandlingRemoteControl = false
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.isHandlingRemoteControl = true
            self.pause()
            self.isHandlingRemoteControl = false
            return .success
        }
        
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.isHandlingRemoteControl = true
            self.playNext()
            self.isHandlingRemoteControl = false
            return .success
        }
        
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.isHandlingRemoteControl = true
            self.playPrevious()
            self.isHandlingRemoteControl = false
            return .success
        }
        
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
        if let id = startedTrackID { libraryStore?.recordEnd(id, completed: false); startedTrackID = nil }
        queue = songs
        currentIndex = index
        if songs.indices.contains(index) {
            loadSong(songs[index])
        }
    }
    
    private func loadSong(_ song: Song) {
		print("loadSong: \(song.title)")
        currentSong = song
        lastListeningSample = nil
        loadAudio(from: libraryStore?.audioURL(for: song) ?? URL.documentsDirectory.appendingPathComponent("tracks").appendingPathComponent(song.fileName))
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
            print("Error loading audio: \(error.localizedDescription)")
        }
    }
    
    private func setupNowPlayingInfo(song: Song) {
        currentSong = song
        
        var mediaArtwork: MPMediaItemArtwork?
        if let artwork = song.artwork {
            let artworkPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(artwork)
            if let uiImage = UIImage(contentsOfFile: artworkPath.path){
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
    }
    
    func updateNowPlayingInfo(song: Song) {
        currentSong = song
        
        var mediaArtwork: MPMediaItemArtwork?
        if let artwork = song.artwork {
            let artworkPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(artwork)
            if let uiImage = UIImage(contentsOfFile: artworkPath.path){
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
    }
    
    func play() {
        amPlayer.Stop()
        print("Play called - current audio player exists: \(audioPlayer != nil)")
        guard audioPlayer?.play() == true else { return }
        if let id = currentSong?.id, startedTrackID != id {
            libraryStore?.recordStart(id); startedTrackID = id
        }
        lastListeningSample = audioPlayer?.currentTime
        isPlaying = true
        startTimer()
        reportPlayback()
    }

    func mapleSnapshot() -> TrackSnapshot? {
        guard let song = currentSong else { return nil }
        return TrackSnapshot(identity: "local:" + song.id.uuidString, title: song.title, artist: song.artist,
            album: song.album, duration: duration, playing: isPlaying, position: audioPlayer?.currentTime ?? currentTime,
            playbackRate: Double(audioPlayer?.rate ?? 1))
    }

    private func reportPlayback() {
        guard let snapshot = mapleSnapshot() else { return }
        var artwork: Data?
        if let path = currentSong?.artwork,
           let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            artwork = try? Data(contentsOf: root.appendingPathComponent(path))
        }
        Task { @MainActor in await playbackReporter?.update(snapshot, artwork: artwork, force: true) }
    }

    func pause() {
        print("Pause called - current audio player exists: \(audioPlayer != nil)")
        audioPlayer?.pause()
        isPlaying = false
        stopTimer()
        reportPlayback()
        if let song = currentSong {
            updateNowPlayingInfo(song: song)
        }
    }
    
    func stop() {
        startedTrackID = nil
        lastListeningSample = nil
        Task { @MainActor in await playbackReporter?.stop() }
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
        lastListeningSample = time
        audioPlayer?.currentTime = time
        currentTime = time
        reportPlayback()
        if let song = currentSong {
            updateNowPlayingInfo(song: song)
        }
    }
    
    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.audioPlayer else { return }
            if self.isPlaying, let id = self.currentSong?.id, let last = self.lastListeningSample {
                let seconds = player.currentTime - last
                Task { @MainActor [weak self] in self?.libraryStore?.recordListening(id, seconds: seconds) }
            }
            self.lastListeningSample = player.currentTime
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
        if let id = startedTrackID { libraryStore?.recordEnd(id, completed: false); startedTrackID = nil }
        print("playNext")
        currentIndex = (currentIndex + 1) % queue.count
        let nextSong = queue[currentIndex]
        print("Loading next song: \(nextSong.title)")
        loadSong(nextSong)

        rpcTask = false
            
        play()
    }
    
    func playPrevious() {
        guard !queue.isEmpty else { return }
        if let id = startedTrackID { libraryStore?.recordEnd(id, completed: false); startedTrackID = nil }
        print("playPrevious")
        currentIndex = (currentIndex - 1 + queue.count) % queue.count
        let previousSong = queue[currentIndex]
        print("Loading previous song: \(previousSong.title)")
        loadSong(previousSong)
        play()
    }
    func enqueueLibraryTracks(_ tracks: [LibraryTrack], next: Bool) {
        if queue.isEmpty { setQueue(tracks); return }
        if next { queue.insert(contentsOf: tracks, at: min(currentIndex + 1, queue.count)) }
        else { queue.append(contentsOf: tracks) }
    }

    func removeLibraryTracks(_ ids: Set<UUID>) {
        let currentID = currentSong?.id
        if let currentID, ids.contains(currentID) { stop(); currentSong = nil; audioPlayer = nil }
        queue.removeAll { ids.contains($0.id) }
        currentIndex = currentID.flatMap { id in queue.firstIndex { $0.id == id } } ?? -1
    }

}


extension AudioPlayerManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if flag {
            if let id = startedTrackID {
                if let last = lastListeningSample { libraryStore?.recordListening(id, seconds: player.duration - last) }
                libraryStore?.recordEnd(id, completed: true)
                startedTrackID = nil
            }
            playNext()
        }
    }
}

struct AudioPlayerView: View {
    @ObservedObject private var audioManager = AudioPlayerManager.shared
    public let song: Song
    public let allSongs: [Song]
    @State private var hasInitializedQueue = false
    
    init(song: Song, allSongs: [Song]) {
        self.song = song
        self.allSongs = allSongs
    }
    
    var body: some View {
        VStack(spacing: 20) {
            if let artworkData = audioManager.currentSong?.artwork {
                let artworkPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(artworkData)
                if let uiImage = UIImage(contentsOfFile: artworkPath.path){
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 160, height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding()
                }
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

            VStack(spacing: 8) {
                Text(audioManager.currentSong?.title ?? song.title)
                    .font(.headline)
                Text(audioManager.currentSong?.artist ?? song.artist)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
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
            
            Button("Stop", systemImage: "stop.fill") { audioManager.stop() }

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
            if !hasInitializedQueue {
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

struct MediaPlayerView: View {
    @ObservedObject private var audioManager = AudioPlayerManager.shared
    public let song: Song
    public let allSongs: [Song]
    @State private var hasInitializedQueue = false
    
    init(song: Song, allSongs: [Song]) {
        self.song = song
        self.allSongs = allSongs
    }
    
    var body: some View {
        VStack(spacing: 20) {
            if let artworkData = audioManager.currentSong?.artwork {
                let artworkPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(artworkData)
                if let uiImage = UIImage(contentsOfFile: artworkPath.path){
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 160, height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding()
                }
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

            VStack(spacing: 8) {
                Text(audioManager.currentSong?.title ?? song.title)
                    .font(.headline)
                Text(audioManager.currentSong?.artist ?? song.artist)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
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
            
            Button("Stop", systemImage: "stop.fill") { audioManager.stop() }

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
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
} 
