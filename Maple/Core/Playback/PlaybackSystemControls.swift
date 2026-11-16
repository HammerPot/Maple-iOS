import AVFoundation
import MediaPlayer
import UIKit

/// The app's only audio-session, remote-command and now-playing owner.
@MainActor final class PlaybackSystemControls {
    private weak var controller: PlaybackController?
    private var targets: [(MPRemoteCommand, Any)] = []
    private var observers: [NSObjectProtocol] = []
    private var resumeAfterInterruption = false
    private var imageData: Data?
    private var artwork: MPMediaItemArtwork?
    private var ownsSession = false

    func bind(_ controller: PlaybackController) {
        self.controller = controller
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand) { [weak controller] in await controller?.resume() }
        add(center.pauseCommand) { [weak controller] in controller?.pause() }
        add(center.togglePlayPauseCommand) { [weak controller] in
            guard let controller else { return }
            if controller.isPlaying { controller.pause() } else { await controller.resume() }
        }
        add(center.nextTrackCommand) { [weak controller] in await controller?.next() }
        add(center.previousTrackCommand) { [weak controller] in await controller?.previous() }
        add(center.stopCommand) { [weak controller] in controller?.stop() }
        let scrub = center.changePlaybackPositionCommand
        let token = scrub.addTarget { [weak controller] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor in await controller?.seek(to: seconds) }
            return .success
        }
        targets.append((scrub, token))
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            Task { @MainActor in self?.interruption(type: type, options: options) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak controller] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in controller?.pause() }
            }
        })
        controller.activateAudio = { [weak self] source in try self?.activate(source) }
        controller.stateChanged = { [weak self] in self?.update() }
    }
    private func add(_ command: MPRemoteCommand, action: @escaping @MainActor () async -> Void) {
        let token = command.addTarget { _ in Task { @MainActor in await action() }; return .success }
        targets.append((command, token))
    }
    private func activate(_ source: PlaybackItem.Source) throws {
        if source == .appleMusic { deactivate(); return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        ownsSession = true
    }
    private func deactivate() {
        guard ownsSession else { return }
        ownsSession = false
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { controller?.onError(error) }
    }
    private func interruption(type: UInt?, options: UInt) {
        guard let controller, controller.currentItem?.source == .local else { return }
        if type == AVAudioSession.InterruptionType.began.rawValue {
            resumeAfterInterruption = controller.isPlaying; controller.pause()
        } else if type == AVAudioSession.InterruptionType.ended.rawValue {
            let shouldResume = resumeAfterInterruption && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            resumeAfterInterruption = false
            if shouldResume { Task { await controller.resume() } }
        }
    }
    private func update() {
        guard let controller else { return }
        let local = controller.currentItem?.source == .local
        // Music.app remains the system now-playing owner during external playback.
        for (command, _) in targets { command.isEnabled = local }
        guard local, let snapshot = controller.snapshot else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            deactivate(); return
        }
        if controller.artworkData != imageData {
            imageData = controller.artworkData
            artwork = imageData.flatMap(UIImage.init(data:)).map { image in
                MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            }
        }
        var info: [String: Any] = [MPMediaItemPropertyTitle: snapshot.title,
            MPMediaItemPropertyArtist: snapshot.artist, MPMediaItemPropertyAlbumTitle: snapshot.album,
            MPMediaItemPropertyPlaybackDuration: snapshot.duration ?? 0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.position,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.playing ? snapshot.playbackRate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: snapshot.playbackRate]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    deinit {
        for (command, token) in targets { command.removeTarget(token) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
