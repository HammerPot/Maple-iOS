import Foundation
import MusicKit

/// Installs a complete segment before Play; Music.app needs no further Maple work to continue it.
@MainActor final class AppleMusicPlaybackEngine: PlaybackEngine {
    var onEvent: ((PlaybackEngineEvent) -> Void)?
    private let backend: any AppleMusicBackend
    private let allowed: () -> Bool
    private var configured = PlaybackQueue()
    private var ownership = AppleMusicQueueOwnership()
    private var preparing = false
    private var lastEntry: UUID?
    private var lastOccurrence: String?
    private(set) var unavailableEntryIDs: Set<UUID> = []
    var position: Double { backend.state.position }
    var duration: Double { backend.state.item?.duration ?? 0 }
    var rate: Double { backend.state.rate }
    var isPlaying: Bool { allowed() && backend.state.status == .playing }
    init(backend: any AppleMusicBackend, allowed: @escaping () -> Bool = { true }) {
        self.backend = backend; self.allowed = allowed
        backend.onChange = { [weak self] in self?.refresh() }
    }
    convenience init() {
        self.init(backend: SystemMusicBackend(), allowed: {
            UserDefaults.standard.bool(forKey: "musicKit") && MusicAuthorization.currentStatus == .authorized
        })
    }
    static func item(_ track: MusicKit.Track) -> PlaybackItem { SystemMusicBackend.item(track) }
    func register(_ values: [MusicKit.Track]) { (backend as? SystemMusicBackend)?.register(values) }
    func configure(_ queue: PlaybackQueue) async throws {
        configured = queue
        backend.configure(repeatMode: AppleMusicQueuePolicy.mapleRepeatMode(for: queue))
    }
    func load(_ item: PlaybackItem) async throws {
        guard allowed() else { throw MapleError(status: 0, message: "Enable Apple Music and allow library access in Settings.") }
        preparing = true
        defer { preparing = false }
        unavailableEntryIDs = []
        let context = AppleMusicQueuePolicy.context(for: configured, fallback: item)
        guard let selected = configured.currentID ?? context.first?.id else { throw CancellationError() }
        let installed = try await backend.prepare(context, selected: selected, progress: { [weak self] in self?.onEvent?(.loadingProgress($0)) })
        try Task.checkCancellation()
        unavailableEntryIDs = installed.unavailable
        ownership.install(installed.entries, selected: selected, observedID: backend.state.occurrence)
        lastEntry = selected; lastOccurrence = backend.state.occurrence
    }
    func externalPlayback() -> ExternalPlaybackState? {
        guard allowed(), !preparing, !ownership.ownsQueue, backend.state.status != .stopped,
              let item = backend.state.item else { return nil }
        return ExternalPlaybackState(item: item, occurrence: backend.state.occurrence ?? item.id)
    }
    func play() async throws { try await backend.play() }
    func pause() { backend.pause() }
    func stop() {
        guard ownership.ownsQueue else { return }
        ownership.relinquish(); backend.stop(); lastEntry = nil; lastOccurrence = nil
    }
    func stopExternalPlayback() {
        guard allowed() else { return }
        ownership.relinquish(); backend.stop(); lastEntry = nil; lastOccurrence = nil
    }
    func skipExternal(forward: Bool) async throws -> Bool {
        guard allowed(), !ownership.ownsQueue, backend.state.item != nil else { return false }
        try await backend.skip(forward: forward); refresh(); return true
    }
    func seek(to seconds: Double) async { backend.seek(to: seconds) }
    func refresh() {
        guard allowed(), !preparing else { return }
        let state = backend.state, result = ownership.observe(backend.state)
        if let item = state.item, result.entry != lastEntry || state.occurrence != lastOccurrence {
            lastEntry = result.entry; lastOccurrence = state.occurrence
            onEvent?(.itemChanged(item, occurrence: state.occurrence ?? item.id, queueEntryID: result.entry))
        }
        if result.ended { onEvent?(.ended) } else { onEvent?(.stateChanged) }
    }
}
