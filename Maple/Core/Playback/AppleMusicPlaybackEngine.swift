import Foundation
import MusicKit
import OSLog

/// Bounds native preparation; extends the native tail without preparing or restarting audio.
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
    private var segment: [PlaybackEntry] = []
    private var installed: [AppleMusicInstalledEntry] = []
    private var installedRange = 0..<0
    private var extending: Task<Void, Never>?
    private var fillAssertion: AppleMusicFillAssertion?
    private let makeFillAssertion: @MainActor () -> AppleMusicFillAssertion
    private var eagerPending = true
    private var lastLazyAttempt: UUID?
    /// Stop eager work after a slow native call returns; never race an uncancellable insertion.
    private static let slowInsertionSeconds = 2.0
    private(set) var unavailableEntryIDs: Set<UUID> = []
    var position: Double {
        let state = backend.state
        ownership.recordPlaying(state)
        return state.position
    }
    var duration: Double { backend.state.item?.duration ?? 0 }
    var rate: Double { backend.state.rate }
    var isPlaying: Bool { allowed() && backend.state.status == .playing }
    init(backend: any AppleMusicBackend, allowed: @escaping () -> Bool = { true },
         makeFillAssertion: @escaping @MainActor () -> AppleMusicFillAssertion = { AppleMusicFillAssertion() }) {
        self.backend = backend; self.allowed = allowed; self.makeFillAssertion = makeFillAssertion
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
        configureNativeModes()
    }
    private func configureNativeModes() {
        let mode = AppleMusicQueuePolicy.mapleRepeatMode(for: configured)
        let complete = installedRange.lowerBound == 0 && installedRange.upperBound == segment.count
        backend.configure(repeatMode: mode == .all && !complete ? .off : mode)
    }
    func load(_ item: PlaybackItem) async throws {
        guard allowed() else { throw MapleError(status: 0, message: "Enable Apple Music and allow library access in Settings.") }
        generation += 1
        cancelExtension(reason: "new selection")
        eagerPending = true; lastLazyAttempt = nil
        let ticket = generation
        preparing = true
        defer { if generation == ticket { preparing = false } }
        unavailableEntryIDs = []
        let context = AppleMusicQueuePolicy.context(for: configured, fallback: item)
        guard let selected = configured.currentID ?? context.first?.id else { throw CancellationError() }
        segment = context
        installedRange = AppleMusicQueuePolicy.window(in: context, selected: selected)
        let result = try await backend.prepare(Array(context[installedRange]), selected: selected, progress: { [weak self] in self?.onEvent?(.loadingProgress($0)) })
        try Task.checkCancellation()
        guard generation == ticket else { throw CancellationError() }
        installed = result.entries
        configureNativeModes()
        unavailableEntryIDs = result.unavailable
        ownership.install(result.entries, selected: selected, observedID: backend.state.occurrence)
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
        cancelExtension(reason: "stop")
        backend.cancelPreparation()
        guard ownership.ownsQueue else { return }
        AppleMusicDiagnostics.logger.info("stop classification=user stop reason=Maple stop or new selection")
        ownership.relinquish(); backend.stop(); lastEntry = nil; lastOccurrence = nil
    }
    func stopExternalPlayback() {
        guard allowed() else { return }
        generation += 1; preparing = false; backend.cancelPreparation()
        cancelExtension(reason: "stop")
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
            AppleMusicDiagnostics.logger.info("notification status=\(state.reportedStatus ?? String(describing: state.status), privacy: .public) song=\(state.item?.id ?? "nil", privacy: .public) kind=\(AppleMusicDiagnostics.kind(state.item), privacy: .public) entry=\(state.occurrence ?? "nil", privacy: .public) modes=\(state.reportedModes ?? "unknown", privacy: .public) decision=ignored songMatch=not-evaluated entryMatch=not-evaluated allowed=\(self.allowed(), privacy: .public) preparing=\(self.preparing, privacy: .public)")
            if state.status == .stopped {
                AppleMusicDiagnostics.logger.info("stop classification=unknown reason=notification while disabled or preparing; no automatic advance")
            }
            return
        }
        let result = ownership.observe(state)
        if let current = result.entry {
            configured.select(current)
            if state.status == .playing { extendIfNeeded(current: current) }
        } else if !ownership.ownsQueue, extending != nil {
            cancelExtension(reason: "ownership lost")
            backend.cancelPreparation()
        }
        AppleMusicDiagnostics.logger.info("notification status=\(state.reportedStatus ?? String(describing: state.status), privacy: .public) song=\(state.item?.id ?? "nil", privacy: .public) kind=\(AppleMusicDiagnostics.kind(state.item), privacy: .public) entry=\(state.occurrence ?? "nil", privacy: .public) position=\(state.position, privacy: .public) modes=\(state.reportedModes ?? "unknown", privacy: .public) decision=\(result.decision, privacy: .public) songMatch=\(result.songMatched, privacy: .public) entryMatch=\(result.entryMatched, privacy: .public)")
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
    private func cancelExtension(reason: String) {
        if extending != nil {
            AppleMusicDiagnostics.logger.info("fill skipped generation=\(self.generation, privacy: .public) reason=\(reason, privacy: .public)")
        }
        fillAssertion?.end(reason: reason); fillAssertion = nil
        extending?.cancel(); extending = nil
    }
    private func extendIfNeeded(current: UUID) {
        guard ownership.ownsQueue, extending == nil, installedRange.upperBound < segment.count,
              let index = installed.firstIndex(where: { $0.entry.id == current }) else { return }
        let eager = eagerPending
        guard eager || (installed.count - index - 1 <= AppleMusicQueuePolicy.refillThreshold && lastLazyAttempt != current) else { return }
        eagerPending = false
        if !eager { lastLazyAttempt = current }
        let ticket = generation
        let assertion = eager ? makeFillAssertion() : nil
        if let assertion {
            fillAssertion = assertion
            guard assertion.start(generation: ticket, onExpiration: { [weak self, weak assertion] in
                guard let self, let assertion, self.fillAssertion === assertion else { return }
                // Cancel pending resolution/insertions. Drain a native insertion already in flight
                // and remember its result, but never issue another eager batch after expiration.
                self.lastLazyAttempt = self.configured.currentID
                self.extending?.cancel()
            }) else {
                fillAssertion = nil
                AppleMusicDiagnostics.logger.info("fill fallback generation=\(ticket, privacy: .public) reason=background assertion denied")
                return
            }
        }
        extending = Task { [weak self] in
            defer { assertion?.end(reason: "completion") }
            guard let self else { return }
            let began = Date()
            defer { if ticket == self.generation { self.extending = nil; self.fillAssertion = nil } }
            repeat {
                guard ticket == self.generation, !Task.isCancelled, self.ownership.ownsQueue,
                      let anchor = self.installed.first(where: { $0.entry.id == self.configured.currentID })?.entry else {
                    AppleMusicDiagnostics.logger.info("fill skipped generation=\(ticket, privacy: .public) reason=cancelled or replaced")
                    return
                }
                let end = min(self.segment.count, self.installedRange.upperBound + AppleMusicQueuePolicy.windowSize)
                let next = Array(self.segment[self.installedRange.upperBound..<end])
                do {
                    let added = try await self.backend.append(next, after: anchor)
                    guard ticket == self.generation, self.ownership.ownsQueue else {
                        AppleMusicDiagnostics.logger.info("fill skipped generation=\(ticket, privacy: .public) reason=cancelled or replaced after insertion")
                        return
                    }
                    self.installed.append(contentsOf: added.entries)
                    self.ownership.append(added.entries)
                    self.unavailableEntryIDs.formUnion(added.unavailable)
                    self.installedRange = self.installedRange.lowerBound..<end
                    self.configureNativeModes()
                    // With the assertion held, UIKit allows this call to finish without suspension.
                    // Expiration cancels the worker and releases the assertion immediately. Its
                    // returned call may include suspended time: retain its inserted entries, then
                    // leave lazy refill to continue; do not classify that interval as slow native work.
                    if Task.isCancelled || assertion?.expired == true { return }
                    if eager && added.insertionSeconds > Self.slowInsertionSeconds {
                        assertion?.end(reason: "slow fallback")
                        AppleMusicDiagnostics.logger.info("fill fallback generation=\(ticket, privacy: .public) reason=slow insertion seconds=\(added.insertionSeconds, privacy: .public)")
                        return
                    }
                } catch {
                    guard ticket == self.generation, !Task.isCancelled else {
                        AppleMusicDiagnostics.logger.info("fill skipped generation=\(ticket, privacy: .public) reason=cancelled or replaced during insertion")
                        return
                    }
                    // Keep playing the installed window. A later track change can retry lazily.
                    self.lastLazyAttempt = self.configured.currentID
                    assertion?.end(reason: "error fallback")
                    AppleMusicDiagnostics.logger.info("fill fallback generation=\(ticket, privacy: .public) reason=insertion error domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code, privacy: .public)")
                    return
                }
            } while eager && self.installedRange.upperBound < self.segment.count
            AppleMusicDiagnostics.logger.info("fill finished generation=\(ticket, privacy: .public) eager=\(eager, privacy: .public) considered=\(self.installedRange.upperBound, privacy: .public)/\(self.segment.count, privacy: .public) installed=\(self.installed.count, privacy: .public) elapsed=\(Date().timeIntervalSince(began), privacy: .public)")
        }
    }
    func waitForExtension() async { await extending?.value }
    func logBoundary(_ boundary: String) {
        let state = backend.state
        AppleMusicDiagnostics.logger.info("boundary=\(boundary, privacy: .public) status=\(state.reportedStatus ?? String(describing: state.status), privacy: .public) song=\(state.item?.id ?? "nil", privacy: .public) kind=\(AppleMusicDiagnostics.kind(state.item), privacy: .public) entry=\(state.occurrence ?? "nil", privacy: .public) position=\(state.position, privacy: .public) modes=\(state.reportedModes ?? "unknown", privacy: .public)")
    }
}
