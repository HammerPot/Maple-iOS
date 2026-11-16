import Foundation
import Observation
import OSLog

@MainActor @Observable
final class PlaybackController {
    private(set) var queue = PlaybackQueue()
    private(set) var currentItem: PlaybackItem?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var duration: Double = 0
    private(set) var artworkData: Data?
    let position = PlaybackPosition()
    @ObservationIgnored var onError: (Error) -> Void = { _ in }
    @ObservationIgnored var recordStart: (UUID) -> Void = { _ in }
    @ObservationIgnored var recordListening: (UUID, Double) -> Void = { _, _ in }
    @ObservationIgnored var recordEnd: (UUID, Bool) -> Void = { _, _ in }
    @ObservationIgnored var stateChanged: () -> Void = {}
    @ObservationIgnored var activateAudio: (PlaybackItem.Source) throws -> Void = { _ in }
    @ObservationIgnored private let local: any PlaybackEngine
    @ObservationIgnored private let apple: any PlaybackEngine
    @ObservationIgnored private let reporter: any PlaybackReporting
    @ObservationIgnored private let persistence: PlaybackPersistence?
    @ObservationIgnored private let clock: () -> TimeInterval
    @ObservationIgnored private let artworkLoader = PlaybackArtwork()
    @ObservationIgnored private var sampling: Task<Void, Never>?
    @ObservationIgnored private var reporting: Task<Void, Never>?
    @ObservationIgnored private var reportRevision = 0
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var deferredAppleRestore = false
    @ObservationIgnored private var wantsPlayback = false
    @ObservationIgnored private var intendedPosition = 0.0
    @ObservationIgnored private var intentRevision = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var playID = UUID()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var listenedAt: TimeInterval?
    @ObservationIgnored private var externalOccurrence: String?
    @ObservationIgnored private var ticks = 0
    private var engine: any PlaybackEngine { currentItem?.source == .appleMusic ? apple : local }

    init(local: any PlaybackEngine, apple: any PlaybackEngine, reporter: any PlaybackReporting,
         persistence: PlaybackPersistence? = nil, automaticSampling: Bool = true,
         clock: @escaping () -> TimeInterval = PlaybackReporter.monotonicNow) {
        self.local = local; self.apple = apple; self.reporter = reporter
        self.persistence = persistence; self.clock = clock
        local.onEvent = { [weak self] in self?.receive($0, source: .local) }
        apple.onEvent = { [weak self] in self?.receive($0, source: .appleMusic) }
        if automaticSampling {
            sampling = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    self?.sample()
                }
            }
        }
    }
    func start(_ items: [PlaybackItem], startingAt index: Int = 0, shuffle: Bool = false) async {
        guard !items.isEmpty else { return }
        endPlay(completed: false)
        queue.replace(items, startingAt: index, shuffle: shuffle)
        await loadCurrent(autoplay: true)
    }
    func playEntry(_ id: UUID) async {
        guard queue.entries.contains(where: { $0.id == id }) else { return }
        endPlay(completed: false); queue.select(id)
        await loadCurrent(autoplay: true)
    }
    private func loadCurrent(autoplay: Bool, at seconds: Double = 0) async {
        deferredAppleRestore = false
        wantsPlayback = autoplay; intendedPosition = seconds; intentRevision += 1
        generation += 1
        let ticket = generation
        local.stop(); apple.stop()
        currentItem = nil; isPlaying = false; isLoading = true; listenedAt = nil
        artworkData = nil; artworkTask?.cancel()
        position.seconds = 0; duration = 0; started = false; playID = UUID()
        await scheduleLoad(ticket: ticket, userInitiated: autoplay).value
    }
    /// Serialize engine mutations: an obsolete prepare must finish before a newer queue is installed.
    /// Generation fences superseded edits; intentRevision fences commands received across awaits.
    private func scheduleLoad(ticket: Int, userInitiated: Bool) -> Task<Void, Never> {
        let previous = loading, context = queue
        let task = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == ticket else { return }
            guard let item = context.current?.item else { self.isLoading = false; return }
            let target = item.source == .local ? self.local : self.apple
            do {
                try await target.configure(context)
                guard self.generation == ticket else { return }
                try await target.load(item)
                guard self.generation == ticket else { return }
                if !target.unavailableEntryIDs.isEmpty {
                    self.queue.remove(target.unavailableEntryIDs)
                    self.onError(MapleError(status: 0, message: "Unavailable Apple Music queue entries were skipped."))
                }
                self.currentItem = item
                self.duration = target.duration > 0 ? target.duration : item.duration
                while self.generation == ticket {
                    let revision = self.intentRevision
                    let seconds = min(self.intendedPosition, max(0, self.duration))
                    if seconds > 0 || target.position != seconds { await target.seek(to: seconds) }
                    guard self.generation == ticket else { return }
                    if revision != self.intentRevision { continue }
                    if self.wantsPlayback {
                        try self.activateAudio(item.source)
                        try await target.play()
                    } else { target.pause() }
                    guard self.generation == ticket else { return }
                    if revision == self.intentRevision { break }
                }
                self.isLoading = false
                self.loadArtwork(item, ticket: ticket)
                self.reconcile(); self.publish(userInitiated: userInitiated && self.wantsPlayback)
                self.save()
            } catch {
                guard self.generation == ticket else { return }
                target.stop(); self.currentItem = nil; self.isPlaying = false; self.isLoading = false
                self.duration = 0; self.position.seconds = 0; self.started = false
                self.publishStop(); self.stateChanged(); self.save()
                if !(error is CancellationError) { self.onError(error) }
            }
        }
        loading = task
        return task
    }
    func resume() async {
        if deferredAppleRestore { await loadCurrent(autoplay: true, at: position.seconds); return }
        wantsPlayback = true; intentRevision += 1
        if isLoading { return }
        guard currentItem != nil else { await loadCurrent(autoplay: true); return }
        do {
            try activateAudio(currentItem?.source ?? .local)
            try await engine.play()
            reconcile(); publish(userInitiated: true)
        } catch { onError(error) }
    }
    func pause() {
        wantsPlayback = false; intentRevision += 1
        if deferredAppleRestore { return }
        if isLoading { local.pause(); apple.pause(); isPlaying = false; return }
        settleListening(); engine.pause(); isPlaying = false; listenedAt = nil
        position.seconds = engine.position; publish(); save()
    }
    func stop() {
        generation += 1; wantsPlayback = false; intentRevision += 1; endPlay(completed: false)
        if currentItem?.source == .appleMusic, !deferredAppleRestore { apple.stopExternalPlayback() }
        deferredAppleRestore = false
        local.stop(); apple.stop(); artworkTask?.cancel(); externalOccurrence = nil
        currentItem = nil; artworkData = nil; isPlaying = false; isLoading = false
        position.seconds = 0; duration = 0
        publishStop(); stateChanged(); save()
    }
    func next(natural: Bool = false) async {
        if !natural, await skipExternal(forward: true) { return }
        endPlay(completed: natural)
        if queue.advance(natural: natural) { await loadCurrent(autoplay: true) }
        else { stop() }
    }
    func previous() async {
        if (deferredAppleRestore ? position.seconds : engine.position) > 3 { await seek(to: 0); return }
        if await skipExternal(forward: false) { return }
        if !queue.previous() { await seek(to: 0); return }
        endPlay(completed: false); await loadCurrent(autoplay: true)
    }
    private func skipExternal(forward: Bool) async -> Bool {
        guard currentItem?.source == .appleMusic, !deferredAppleRestore else { return false }
        do {
            if try await apple.skipExternal(forward: forward) { refresh(); return true }
        } catch { onError(error); return true }
        return false
    }
    /// Called once on release, by a lyric line or by a remote command, never per slider tick.
    func seek(to seconds: Double) async {
        guard (currentItem ?? queue.current?.item) != nil, seconds.isFinite else { return }
        intendedPosition = max(0, seconds); intentRevision += 1
        if deferredAppleRestore { position.seconds = intendedPosition; save(); return }
        if isLoading { position.seconds = intendedPosition; return }
        settleListening(); listenedAt = nil
        let ticket = generation
        await engine.seek(to: min(max(0, seconds), max(0, duration)))
        guard ticket == generation else { return }
        position.seconds = engine.position; listenedAt = isPlaying ? clock() : nil
        publish(); save()
    }
    func setShuffle(_ enabled: Bool) { queue.setShuffle(enabled); synchronizeEngineQueue(reload: true); save() }
    func setRepeat(_ mode: PlaybackRepeat) { queue.repeatMode = mode; synchronizeEngineQueue(); save() }
    func enqueue(_ items: [PlaybackItem], next: Bool) { queue.enqueue(items, next: next); synchronizeEngineQueue(reload: true); save() }
    func moveUpcoming(from offsets: IndexSet, to destination: Int) { queue.moveUpcoming(from: offsets, to: destination); synchronizeEngineQueue(reload: true); save() }
    func removeEntries(_ ids: Set<UUID>) {
        if let id = queue.currentID, ids.contains(id) { stop() }
        queue.remove(ids); synchronizeEngineQueue(reload: true); save()
    }
    func removeLibraryTracks(_ ids: Set<UUID>) {
        if (currentItem?.libraryID ?? queue.current?.item.libraryID).map(ids.contains) == true { stop() }
        queue.removeLibraryTracks(ids); synchronizeEngineQueue(reload: true); save()
    }
    private func synchronizeEngineQueue(reload: Bool = false) {
        guard (currentItem ?? queue.current?.item)?.source == .appleMusic, !deferredAppleRestore else { return }
        if !reload, !isLoading {
            let previous = loading, context = queue, ticket = generation
            loading = Task { [weak self] in
                await previous?.value
                guard let self, self.generation == ticket else { return }
                do { try await self.apple.configure(context) } catch { self.onError(error) }
            }
            return
        }
        if !isLoading { intendedPosition = engine.position; wantsPlayback = isPlaying }
        generation += 1; isLoading = true
        _ = scheduleLoad(ticket: generation, userInitiated: false)
    }
    func waitForLoad() async { await loading?.value }
    var snapshot: TrackSnapshot? {
        guard let item = currentItem else { return nil }
        return TrackSnapshot(identity: "\(item.source == .local ? "local" : "apple"):\(item.id):\(playID)",
            title: item.title, artist: item.artist, album: item.album, duration: duration,
            playing: isPlaying, position: deferredAppleRestore ? position.seconds : engine.position, playbackRate: engine.rate)
    }
    func sample() {
        guard currentItem != nil, !isLoading, !deferredAppleRestore else { return }
        let nextPosition = engine.position
        // Music.app can repeat one queue entry without changing its entry ID or playback status.
        // Reuse the cheap position sample to recognize that boundary; explicit Maple seeks update
        // position immediately and therefore cannot look like a natural wrap on the next sample.
        let repeatsCurrent = queue.repeatMode == .one || (queue.repeatMode == .all && queue.entries.count == 1)
        if currentItem?.source == .appleMusic, repeatsCurrent, isPlaying, engine.isPlaying,
           duration > 4, position.seconds >= duration - 2, nextPosition <= 2 {
            endPlay(completed: true); playID = UUID()
            reconcile(); publish(); save()
        } else {
            settleListening()
            position.seconds = nextPosition
        }
        ticks += 1
        if ticks % 10 == 0 { save() }
    }
    func refresh() {
        if adoptExternalPlayback() { return }
        reconcile(); publish()
    }
    /// Observation does not confer ownership of Music.app's queue; never configure/load on adoption.
    @discardableResult private func adoptExternalPlayback() -> Bool {
        guard !isLoading, let state = apple.externalPlayback(),
              currentItem?.source != .appleMusic || externalOccurrence != state.occurrence else { return false }
        endPlay(completed: false)
        local.stop()
        generation += 1; artworkTask?.cancel(); deferredAppleRestore = false
        queue.replace([state.item], startingAt: 0, shuffle: false)
        currentItem = state.item; externalOccurrence = state.occurrence
        playID = UUID(); artworkData = nil; wantsPlayback = true
        loadArtwork(state.item, ticket: generation)
        reconcile(); publish(); save()
        return true
    }
    private func reconcile() {
        guard currentItem != nil, !isLoading, !deferredAppleRestore else { return }
        settleListening()
        let playing = engine.isPlaying
        if playing && !started {
            started = true
            if let id = currentItem?.libraryID { recordStart(id) }
        }
        isPlaying = playing
        listenedAt = playing ? clock() : nil
        if engine.duration > 0 { duration = engine.duration }
        position.seconds = engine.position
    }
    private func settleListening() {
        defer { listenedAt = isPlaying ? clock() : nil }
        guard started, let id = currentItem?.libraryID, let previous = listenedAt else { return }
        var seconds = max(0, clock() - previous)
        // The store accepts bounded samples; delayed scheduling/background work must not discard time.
        while seconds > 0 { let part = min(seconds, 5); recordListening(id, part); seconds -= part }
    }
    private func endPlay(completed: Bool) {
        settleListening()
        if started, let id = currentItem?.libraryID { recordEnd(id, completed) }
        started = false; listenedAt = nil
    }
    private func receive(_ event: PlaybackEngineEvent, source: PlaybackItem.Source) {
        guard !isLoading else { return }
        switch event {
        case .itemChanged(let item, let occurrence, let queueEntryID):
            guard source == .appleMusic else { return }
            if queueEntryID == nil, adoptExternalPlayback() { return }
            if currentItem?.source != .appleMusic { _ = adoptExternalPlayback(); return }
            guard externalOccurrence != occurrence else { return }
            externalOccurrence = occurrence
            if let queueEntryID { queue.select(queueEntryID) }
            // Music.app can move its system queue independently of Maple.
            endPlay(completed: false); currentItem = item; playID = UUID(); artworkData = nil
            loadArtwork(item, ticket: generation); reconcile(); publish(); save()
        case .stateChanged:
            if source == .appleMusic, adoptExternalPlayback() { return }
            guard currentItem?.source == source else { return }
            reconcile(); publish()
        case .ended:
            guard currentItem?.source == source else { return }
            let ticket = generation
            Task { [weak self] in
                guard let self, self.generation == ticket, !self.isLoading else { return }
                await self.next(natural: true)
            }
        case .failed(let error):
            guard currentItem?.source == source else { return }
            stop(); onError(error)
        }
    }
    private func publish(userInitiated: Bool = false) {
        stateChanged()
        guard let value = snapshot else { return }
        reportRevision += 1
        let revision = reportRevision
        let previous = reporting; let reporter = reporter; let data = artworkData
        reporting = Task { [weak self] in
            await previous?.value
            guard let self, self.reportRevision == revision else { return }
            await reporter.update(value, artwork: data, force: true)
            if userInitiated, self.reportRevision == revision { await reporter.playbackStarted() }
        }
    }
    private func publishStop() {
        reportRevision += 1
        let revision = reportRevision
        let previous = reporting; let reporter = reporter
        reporting = Task { [weak self] in
            await previous?.value
            guard let self, self.reportRevision == revision else { return }
            await reporter.stop()
        }
    }
    private func loadArtwork(_ item: PlaybackItem, ticket: Int) {
        guard let url = item.artworkURL else { return }
        artworkTask = Task { [weak self] in
            let data = await self?.artworkLoader.read(url)
            guard let self, self.generation == ticket, self.currentItem?.id == item.id, !Task.isCancelled else { return }
            self.artworkData = data; self.stateChanged()

        }
    }
    func artworkForClaim(identity: String) async -> Data? {
        guard snapshot?.identity == identity, let item = currentItem, let url = item.artworkURL else { return nil }
        let data = await artworkLoader.read(url)
        return snapshot?.identity == identity ? data : nil
    }
    func save() {
        guard let persistence else { return }
        let value = PlaybackCheckpoint(queue: queue, position: currentItem == nil ? 0 : (deferredAppleRestore ? position.seconds : engine.position))
        let previous = saving
        saving = Task { [weak self] in
            await previous?.value
            do { try await persistence.save(value) } catch { self?.onError(error) }
        }
    }
    func restore(localItem: (UUID) -> PlaybackItem?) async {
        if adoptExternalPlayback() { return }
        guard let persistence else { return }
        do {
            guard let saved = try await persistence.load(), currentItem == nil, queue.entries.isEmpty else { return }
            if adoptExternalPlayback() { return }
            queue = saved.queue
            let missing = Set(queue.entries.filter { entry in
                entry.item.source == .local && entry.item.libraryID.flatMap(localItem) == nil
            }.map(\.id))
            queue.remove(missing)
            // Rebase local URLs after reinstall/container changes, keeping occurrence IDs and order.
            var refreshed = queue
            refreshed.rebaseLocalItems(localItem)
            queue = refreshed
            if let item = queue.current?.item, item.source == .appleMusic {
                // Restoring Maple metadata is passive. Do not replace even a paused Music.app queue,
                // or interrupt unrelated audio, until the user explicitly asks Maple to play.
                deferredAppleRestore = true; currentItem = item; isPlaying = false
                duration = item.duration; position.seconds = max(0, saved.position)
                loadArtwork(item, ticket: generation); stateChanged()
            } else { await loadCurrent(autoplay: false, at: saved.position) }
        } catch { onError(error) }
    }
    func waitForReports() async { await reporting?.value }
    func waitForSave() async { await saving?.value }
    deinit { sampling?.cancel(); artworkTask?.cancel() }
}
