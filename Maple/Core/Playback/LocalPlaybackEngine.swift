import AVFoundation
import Foundation

@MainActor final class LocalPlaybackEngine: PlaybackEngine {
    var onEvent: ((PlaybackEngineEvent) -> Void)?
    private let player = AVPlayer()
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var itemStatusObserver: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    private var generation = 0
    var position: Double { let t = player.currentTime().seconds; return t.isFinite ? max(0, t) : 0 }
    var duration: Double { let t = player.currentItem?.duration.seconds ?? 0; return t.isFinite ? max(0, t) : 0 }
    var rate: Double { player.rate > 0 ? Double(player.rate) : 1 }
    var isPlaying: Bool { player.timeControlStatus == .playing }

    init() {
        statusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.onEvent?(.stateChanged) }
        }
    }
    func load(_ item: PlaybackItem) async throws {
        stop()
        let ticket = generation
        guard let url = item.audioURL else { throw LibraryError.unreadableAudio }
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else { throw LibraryError.unreadableAudio }
        _ = try await asset.load(.duration)
        try Task.checkCancellation()
        guard generation == ticket else { throw CancellationError() }
        let new = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: new)
        itemStatusObserver = new.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                guard let self, self.generation == ticket else { return }
                self.onEvent?(.failed(LibraryError.unreadableAudio))
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: new, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == ticket else { return }
                self.onEvent?(.ended)
            }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: new, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == ticket else { return }
                self.onEvent?(.failed(LibraryError.unreadableAudio))
            }
        }
    }
    func play() async throws {
        guard player.currentItem != nil else { throw LibraryError.unreadableAudio }
        if let error = player.currentItem?.error { throw error }
        player.play()
    }
    func pause() { player.pause() }
    func stop() {
        generation += 1
        player.pause(); player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil; failureObserver = nil; itemStatusObserver = nil
    }
    func seek(to seconds: Double) async {
        await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
    }
}
