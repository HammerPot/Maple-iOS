import Foundation
import MusicKit
import OSLog

/// Installs a complete segment before Play; Music.app needs no further Maple work to continue it.
@MainActor final class AppleMusicPlaybackEngine: PlaybackEngine {
    var onEvent: ((PlaybackEngineEvent) -> Void)?
    private let backend: any AppleMusicBackend
    private let allowed: () -> Bool
    private var configured = PlaybackQueue()
    private var ownership = AppleMusicQueueOwnership()
    private var preparing = false
    private var generation = 0
    private var lastEntry: UUID?
    private var lastOccurrence: String?
    private(set) var unavailableEntryIDs: Set<UUID> = []
    var position: Double {
        let state = backend.state
        ownership.recordPlaying(state)
        return state.position
    }
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
        let ticket = generation
        preparing = true
        defer { if generation == ticket { preparing = false } }
        unavailableEntryIDs = []
        let context = AppleMusicQueuePolicy.context(for: configured, fallback: item)
        guard let selected = configured.currentID ?? context.first?.id else { throw CancellationError() }
        let installed = try await backend.prepare(context, selected: selected, progress: { [weak self] in self?.onEvent?(.loadingProgress($0)) })
        try Task.checkCancellation()
        guard generation == ticket else { throw CancellationError() }
        backend.configure(repeatMode: AppleMusicQueuePolicy.mapleRepeatMode(for: configured))
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
        generation += 1; preparing = false
        backend.cancelPreparation()
        guard ownership.ownsQueue else { return }
        AppleMusicDiagnostics.logger.info("stop classification=user stop reason=Maple stop or new selection")
        ownership.relinquish(); backend.stop(); lastEntry = nil; lastOccurrence = nil
    }
    func stopExternalPlayback() {
        guard allowed() else { return }
        generation += 1; preparing = false; backend.cancelPreparation()
        AppleMusicDiagnostics.logger.info("stop classification=user stop reason=explicit external Stop")
        ownership.relinquish(); backend.stop(); lastEntry = nil; lastOccurrence = nil
    }
    func skipExternal(forward: Bool) async throws -> Bool {
        guard allowed(), !ownership.ownsQueue, backend.state.item != nil else { return false }
        try await backend.skip(forward: forward); refresh(); return true
    }
    func seek(to seconds: Double) async { backend.seek(to: seconds) }
    func refresh() {
        let state = backend.state
        guard allowed(), !preparing else {
            AppleMusicDiagnostics.logger.debug("notification status=\(state.reportedStatus ?? String(describing: state.status), privacy: .public) song=\(state.item?.id ?? "nil", privacy: .public) kind=\(AppleMusicDiagnostics.kind(state.item), privacy: .public) entry=\(state.occurrence ?? "nil", privacy: .public) modes=\(state.reportedModes ?? "unknown", privacy: .public) decision=ignored songMatch=not-evaluated entryMatch=not-evaluated allowed=\(self.allowed(), privacy: .public) preparing=\(self.preparing, privacy: .public)")
            if state.status == .stopped {
                AppleMusicDiagnostics.logger.info("stop classification=unknown reason=notification while disabled or preparing; no automatic advance")
            }
            return
        }
        let result = ownership.observe(state)
        AppleMusicDiagnostics.logger.debug("notification status=\(state.reportedStatus ?? String(describing: state.status), privacy: .public) song=\(state.item?.id ?? "nil", privacy: .public) kind=\(AppleMusicDiagnostics.kind(state.item), privacy: .public) entry=\(state.occurrence ?? "nil", privacy: .public) position=\(state.position, privacy: .public) modes=\(state.reportedModes ?? "unknown", privacy: .public) decision=\(result.decision, privacy: .public) songMatch=\(result.songMatched, privacy: .public) entryMatch=\(result.entryMatched, privacy: .public)")
        if state.status == .stopped || result.stopReason.hasPrefix("takeover") {
            AppleMusicDiagnostics.logger.info("stop classification=\(result.ended ? "natural end" : (result.stopReason.hasPrefix("takeover") ? "takeover" : "unknown"), privacy: .public) reason=\(result.stopReason, privacy: .public)")
        }
        // Entry-ID rewrites never create a new Maple play. For external sessions the system ID
        // remains useful to distinguish occurrences, because there is no Maple occurrence to follow.
        let changed = result.entry != nil ? result.entry != lastEntry : state.occurrence != lastOccurrence
        if !result.stopped && !result.ended, let item = state.item, changed {
            onEvent?(.itemChanged(item, occurrence: state.occurrence ?? item.id, queueEntryID: result.entry))
        }
        if !result.stopped && !result.ended { lastEntry = result.entry; lastOccurrence = state.occurrence }
        if result.ended { onEvent?(.ended) }
        else if result.stopped { onEvent?(.stopped) }
        else { onEvent?(.stateChanged) }
    }
    func logBoundary(_ boundary: String) {
        let state = backend.state
        AppleMusicDiagnostics.logger.info("boundary=\(boundary, privacy: .public) status=\(state.reportedStatus ?? String(describing: state.status), privacy: .public) song=\(state.item?.id ?? "nil", privacy: .public) kind=\(AppleMusicDiagnostics.kind(state.item), privacy: .public) entry=\(state.occurrence ?? "nil", privacy: .public) position=\(state.position, privacy: .public) modes=\(state.reportedModes ?? "unknown", privacy: .public)")
    }
}
