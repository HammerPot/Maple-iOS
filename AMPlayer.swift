import Combine
import Foundation
import MusicKit
import SwiftUI

@MainActor
final class AMPlayer: ObservableObject {
    static let shared = AMPlayer()
    @Published private(set) var albumArt: PlatformImage?
    @Published private(set) var initialized = false
    @Published private(set) var isPlaying = false
    @Published private(set) var title = "No song playing"
    @Published private(set) var artist = "Unknown artist"
    @Published private(set) var duration: TimeInterval = 0
    @Published var errorMessage: String?

    private var observations = Set<AnyCancellable>()
    private var artworkTask: Task<Void, Never>?
    private var queueTask: Task<Void, Never>?
    private var artworkTrackID: MusicItemID?
    private var lastSnapshot: MaplePlaybackSnapshot?

    private init() {
        MapleMusicPlayer.shared.state.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.refresh() }
        }.store(in: &observations)
        MapleMusicPlayer.shared.queue.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.refresh() }
        }.store(in: &observations)
        initialized = MapleMusicPlayer.shared.queue.currentEntry != nil
        Task { @MainActor [weak self] in self?.refresh() }
    }

    private func refresh() {
        let wasPlaying = isPlaying
        let wasInitialized = initialized
        isPlaying = MapleMusicPlayer.shared.state.playbackStatus == .playing
        initialized = isPlaying || (initialized && MapleMusicPlayer.shared.queue.currentEntry != nil)
        if let entry = MapleMusicPlayer.shared.queue.currentEntry, case .song(let song) = entry.item {
            title = song.title
            artist = song.artistName
            duration = song.duration ?? 0
            if artworkTrackID != song.id {
                artworkTrackID = song.id
                albumArt = nil
                artworkTask?.cancel()
                if let url = song.artwork?.url(width: 640, height: 640) {
                    artworkTask = Task { [weak self] in
                        do {
                            let (data, _) = try await URLSession.shared.data(from: url)
                            try Task.checkCancellation()
                            guard let self, self.initialized, self.artworkTrackID == song.id else { return }
                            self.albumArt = PlatformImage(data: data)
                            self.reportPlayback(claim: false)
                        } catch { /* Artwork is optional; playback remains available. */ }
                    }
                }
            }
        } else {
            title = "No song playing"
            artist = "Unknown artist"
            duration = 0
            albumArt = nil
            artworkTrackID = nil
            artworkTask?.cancel()
        }
        if isPlaying && !wasPlaying { AudioPlayerManager.shared.stop() }
        if initialized || wasInitialized { reportPlayback(claim: isPlaying && !wasPlaying) }
    }

    func playbackSnapshot() -> MaplePlaybackSnapshot? {
        guard let entry = MapleMusicPlayer.shared.queue.currentEntry, case .song(let song) = entry.item else {
            guard let last = lastSnapshot else { return nil }
            return MaplePlaybackSnapshot(trackID: last.trackID, source: last.source, title: last.title,
                                         artist: last.artist, album: last.album, playing: false,
                                         position: 0, duration: last.duration)
        }
        return MaplePlaybackSnapshot(trackID: song.id.rawValue, source: "Apple Music", title: song.title,
                                     artist: song.artistName, album: song.albumTitle ?? "Unknown Album",
                                     playing: MapleMusicPlayer.shared.state.playbackStatus == .playing,
                                     position: MapleMusicPlayer.shared.playbackTime, duration: song.duration ?? 0)
    }

    func reportPlayback(claim: Bool) {
        guard let snapshot = playbackSnapshot() else { return }
        lastSnapshot = snapshot
        let artwork = albumArt?.jpegData(compressionQuality: 0.85) ?? PlatformImage(named: "Maple")?.jpegData(compressionQuality: 0.85)
        AppSocketManager.shared.updatePlayback({ [weak self] in self?.playbackSnapshot() }, artwork: artwork, claim: claim)
    }

    func queue2(song: MusicKit.Track, allSongs: [MusicKit.Track], type: String) {
        queueTask?.cancel()
        queueTask = Task {
            do {
                let tracks = allSongs.contains(where: { $0.id == song.id }) ? allSongs : [song]
                MapleMusicPlayer.shared.queue = .init(for: tracks, startingAt: song)
                try Task.checkCancellation()
                try await MapleMusicPlayer.shared.play()
                try Task.checkCancellation()
                refresh()
                reportPlayback(claim: true)
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func togglePlayback() async {
        do {
            if MapleMusicPlayer.shared.state.playbackStatus == .playing {
                MapleMusicPlayer.shared.pause()
            } else {
                try await MapleMusicPlayer.shared.play()
            }
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func skip(next: Bool) async {
        do {
            if next { try await MapleMusicPlayer.shared.skipToNextEntry() }
            else { try await MapleMusicPlayer.shared.skipToPreviousEntry() }
            refresh()
            reportPlayback(claim: isPlaying)
        } catch { errorMessage = error.localizedDescription }
    }

    func Stop() {
        guard initialized || queueTask != nil else { return }
        queueTask?.cancel()
        queueTask = nil
        artworkTask?.cancel()
        MapleMusicPlayer.shared.stop()
        isPlaying = false
        initialized = false
        reportPlayback(claim: false)
    }
}

struct AMPlayerView: View {
    let song: MusicKit.Track
    let allSongs: [MusicKit.Track]
    let type: String
    @State private var hasInitializedQueue = false

    var body: some View {
        AMPlayerView2()
            .onAppear {
                guard !hasInitializedQueue else { return }
                hasInitializedQueue = true
                AMPlayer.shared.queue2(song: song, allSongs: allSongs, type: type)
            }
    }
}

struct AMPlayerView2: View {
    @ObservedObject private var player = AMPlayer.shared
    @State private var currentTime: TimeInterval = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Group {
                    if let artwork = player.albumArt {
                        Image(platformImage: artwork).resizable()
                    } else {
                        Image("Maple").resizable()
                    }
                }
                .scaledToFit()
                .frame(maxWidth: 240, maxHeight: 240)
                .clipShape(.rect(cornerRadius: 8))
                .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text(player.title).font(.headline)
                    Text(player.artist).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 24) {
                    Button("Previous Track", systemImage: "backward.fill") {
                        Task { await player.skip(next: false) }
                    }
                    Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                        Task { await player.togglePlayback() }
                    }
                    Button("Next Track", systemImage: "forward.fill") {
                        Task { await player.skip(next: true) }
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!player.initialized)
                VStack {
                    Slider(value: Binding(get: { min(max(currentTime, 0), max(player.duration, 1)) }, set: { newTime in
                        currentTime = newTime
                        MapleMusicPlayer.shared.playbackTime = newTime
                        player.reportPlayback(claim: true)
                    }), in: 0...max(player.duration, 1))
                    .accessibilityLabel("Playback position")
                    .disabled(player.duration <= 0)
                    HStack {
                        Text(Duration.seconds(max(currentTime, 0)), format: .time(pattern: .minuteSecond))
                        Spacer()
                        Text(Duration.seconds(max(player.duration, 0)), format: .time(pattern: .minuteSecond))
                    }.font(.caption).monospacedDigit()
                }
            }
            .padding()
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            currentTime = MapleMusicPlayer.shared.playbackTime
        }
    }
}
