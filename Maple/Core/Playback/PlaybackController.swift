import Foundation
import Observation
import OSLog

@MainActor @Observable
final class PlaybackController {
    private(set) var queue = PlaybackQueue()
    private(set) var currentItem: PlaybackItem?
    var playingFromMusic: Bool { parked != nil }
    private struct ParkedPlayback {
        var item: PlaybackItem?
        var position: Double
        var duration: Double
        var artwork: Data?
        var playID: UUID
    }
    private var parked: ParkedPlayback?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var loadingProgress = 0.0
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
    @ObservationIgnored private var checkpointKey: UUID?
    @ObservationIgnored private var positionSavedAt = 0.0
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var deferredRestore = false
    @ObservationIgnored private var wantsPlayback = false
    @ObservationIgnored private var intendedPosition = 0.0
    @ObservationIgnored private var intentRevision = 0
    @ObservationIgnored private let chooseShuffleStart: (Range<Int>) -> Int
    @ObservationIgnored private var failedSkippedEntry: UUID?
    @ObservationIgnored private var skippingUnreadable = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var playID = UUID()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var listenedAt: TimeInterval?
    @ObservationIgnored private var externalOccurrence: String?
    @ObservationIgnored private let automaticSampling: Bool
    @ObservationIgnored private let samplingSleep: @Sendable (Duration) async throws -> Void
    private var engine: any PlaybackEngine { currentItem?.source == .appleMusic ? apple : local }

    init(local: any PlaybackEngine, apple: any PlaybackEngine, reporter: any PlaybackReporting,
         persistence: PlaybackPersistence? = nil, automaticSampling: Bool = true,
         clock: @escaping () -> TimeInterval = PlaybackReporter.monotonicNow,
         chooseShuffleStart: @escaping (Range<Int>) -> Int = { Int.random(in: $0) },
         samplingSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.local = local; self.apple = apple; self.reporter = reporter
        self.persistence = persistence; self.clock = clock
        self.automaticSampling = automaticSampling; self.samplingSleep = samplingSleep
        self.chooseShuffleStart = chooseShuffleStart
        local.onEvent = { [weak self] in self?.receive($0, source: .local) }
        apple.onEvent = { [weak self] in self?.receive($0, source: .appleMusic) }
    }
    private func synchronizeSampling() {
        guard automaticSampling, isPlaying, !isLoading else { sampling?.cancel(); sampling = nil; return }
        guard sampling == nil else { return }
        let sleep = samplingSleep
        sampling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(.milliseconds(500)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.sample()
            }
        }
    }
    func start(_ items: [PlaybackItem], startingAt index: Int? = nil, shuffle: Bool = false) async {
        guard !items.isEmpty else { return }
        leaveExternalPlayback()
        endPlay(completed: false)
        queue.replace(items, startingAt: index ?? (shuffle ? chooseShuffleStart(items.indices) : 0), shuffle: shuffle)
        await loadCurrent(autoplay: true)
    }
    func playEntry(_ id: UUID) async {
        guard !playingFromMusic, queue.entries.contains(where: { $0.id == id }) else { return }
        endPlay(completed: false); queue.select(id)
        await loadCurrent(autoplay: true)
    }
    private func loadCurrent(autoplay: Bool, at seconds: Double = 0, skipUnreadable: Bool = false, backward: Bool = false, userInitiated: Bool = true) async {
        var nextPosition = seconds
        var restoredPlayID: UUID? = deferredRestore ? playID : nil
        wantsPlayback = autoplay
        repeat {
            deferredRestore = false
            intendedPosition = nextPosition; intentRevision += 1
            generation += 1
            let ticket = generation
            local.stop(); apple.stop()
            currentItem = nil; isPlaying = false; isLoading = true; loadingProgress = 0; listenedAt = nil
            synchronizeSampling()
            artworkData = nil; artworkTask?.cancel()
            position.seconds = 0; duration = 0; started = false
            playID = restoredPlayID ?? UUID(); restoredPlayID = nil
            failedSkippedEntry = nil; skippingUnreadable = skipUnreadable
            await scheduleLoad(ticket: ticket, userInitiated: userInitiated && autoplay).value
            guard generation == ticket, let failed = failedSkippedEntry else { return }
            // Remove each unreadable occurrence once; even repeat-one/all can make at most one pass.
            let following: UUID?
            if backward, let index = queue.index {
                following = index > 0 ? queue.entries[index - 1].id : (queue.repeatMode == .all ? queue.entries.last(where: { $0.id != failed })?.id : nil)
            } else {
                following = queue.upcoming.first?.id ?? (queue.repeatMode == .all ? queue.entries.first(where: { $0.id != failed })?.id : nil)
            }
            queue.remove([failed])
            guard let following else {
                stop()
                if let first = queue.entries.first { queue.select(first.id); save() }
                return
            }
            queue.select(following); nextPosition = 0
        } while !queue.entries.isEmpty
        stop()
    }
    /// Cancel superseded preparation; a new user choice never waits for abandoned framework work.
    /// Generation protects controller state; engines fence installation after their own awaits.
    private func scheduleLoad(ticket: Int, userInitiated: Bool) -> Task<Void, Never> {
        loading?.cancel()
        let context = queue
        let task = Task { [weak self] in
            guard let self, self.generation == ticket else { return }
            guard let item = context.current?.item else { self.isLoading = false; return }
            let target = item.source == .local ? self.local : self.apple
            var unreadableFile = false
            var unavailableMusic = false
            do {
                try await target.configure(context)
                guard self.generation == ticket else { return }
                do { try await target.load(item) }
                catch {
                    if item.source == .local, case LibraryError.unreadableAudio = error { unreadableFile = true }
                    if item.source == .appleMusic, let resolution = error as? AppleMusicResolutionError,
                       resolution == .notFound || resolution == .notPlayable { unavailableMusic = true }
                    throw error
                }
                guard self.generation == ticket else { return }
                if !target.unavailableEntryIDs.isEmpty {
                    self.queue.remove(target.unavailableEntryIDs)
                    self.onError(MapleError(status: 0, message: "Unavailable Apple Music queue entries were skipped."))
                }
                self.currentItem = item
                self.duration = target.duration > 0 ? target.duration : item.duration
                while self.generation == ticket {
                    let revision = self.intentRevision
                    let seconds = (self.duration > 0 ? min(self.intendedPosition, self.duration) : self.intendedPosition)
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
                target.finishLoading()
                self.loadArtwork(item, ticket: ticket)
                self.reconcile(); self.publish(userInitiated: userInitiated && self.wantsPlayback)
                self.save()
            } catch {
                guard self.generation == ticket else { return }
                target.stop(); self.currentItem = nil; self.isPlaying = false; self.isLoading = false
                self.duration = 0; self.position.seconds = 0; self.started = false
                self.synchronizeSampling()
                if unavailableMusic || (self.skippingUnreadable && unreadableFile) {
                    self.failedSkippedEntry = context.currentID
                    self.onError(MapleError(status: 0, message: unavailableMusic ? "An unavailable Apple Music track was skipped: \(item.title)" : "An unreadable audio file was skipped: \(item.title)"))
                } else {
                    self.publishStop(); self.stateChanged(); self.save()
                    if !(error is CancellationError) { self.onError(error) }
                }
            }
        }
        loading = task
        return task
    }
    func resume(userInitiated: Bool = true) async {
        if deferredRestore, !userInitiated { return }
        if deferredRestore { await loadCurrent(autoplay: true, at: position.seconds, userInitiated: userInitiated); return }
        wantsPlayback = true; intentRevision += 1
        if isLoading { return }
        guard currentItem != nil else { await loadCurrent(autoplay: true, userInitiated: userInitiated); return }
        do {
            try activateAudio(currentItem?.source ?? .local)
            try await engine.play()
            reconcile(); publish(userInitiated: userInitiated)
        } catch { onError(error) }
    }
    func pause() {
        wantsPlayback = false; intentRevision += 1
        if deferredRestore { return }
        if isLoading {
            (queue.current?.item.source == .appleMusic ? apple : local).pause()
            isPlaying = false; synchronizeSampling(); return
        }
        settleListening(); engine.pause(); isPlaying = false; listenedAt = nil
        position.seconds = engine.position; synchronizeSampling(); publish(); save()
    }
    func stop() {
        if playingFromMusic {
            apple.stopExternalPlayback(); leaveExternalPlayback(); publishStop(); stateChanged(); return
        }
        loading?.cancel()
        generation += 1; wantsPlayback = false; intentRevision += 1; endPlay(completed: false)
        if currentItem?.source == .appleMusic, !deferredRestore { apple.stopExternalPlayback() }
        deferredRestore = false
        local.stop(); apple.stop(); artworkTask?.cancel(); externalOccurrence = nil
        currentItem = nil; artworkData = nil; isPlaying = false; isLoading = false
        position.seconds = 0; duration = 0; synchronizeSampling()
        publishStop(); stateChanged(); save()
    }
    func next(natural: Bool = false) async {
        if playingFromMusic {
            if !natural { _ = await skipExternal(forward: true) }
            return
        }
        endPlay(completed: natural)
        if queue.advance(natural: natural) { await loadCurrent(autoplay: true, skipUnreadable: natural) }
        else { stop() }
    }
    func previous() async {
        if playingFromMusic { _ = await skipExternal(forward: false); return }
        if (deferredRestore ? position.seconds : engine.position) > 3 { await seek(to: 0); return }
        if !queue.previous() { await seek(to: 0); return }
        endPlay(completed: false); await loadCurrent(autoplay: true, backward: true)
    }
    private func skipExternal(forward: Bool) async -> Bool {
        guard playingFromMusic else { return false }
        do {
            if try await apple.skipExternal(forward: forward) { refresh(); return true }
        } catch { onError(error); return true }
        return false
    }
    /// Called once on release, by a lyric line or by a remote command, never per slider tick.
    func seek(to seconds: Double) async {
        guard (currentItem ?? queue.current?.item) != nil, seconds.isFinite else { return }
        intendedPosition = max(0, seconds); intentRevision += 1
        if deferredRestore { position.seconds = intendedPosition; save(); return }
        if isLoading { position.seconds = intendedPosition; return }
        settleListening(); listenedAt = nil
        let ticket = generation
        await engine.seek(to: duration > 0 ? min(max(0, seconds), duration) : max(0, seconds))
        guard ticket == generation else { return }
        position.seconds = engine.position; listenedAt = isPlaying ? clock() : nil
        publish(); save()
    }
    func setShuffle(_ enabled: Bool) { guard !playingFromMusic else { return }; queue.setShuffle(enabled); synchronizeEngineQueue(reload: true); save() }
    func setRepeat(_ mode: PlaybackRepeat) { guard !playingFromMusic else { return }; queue.repeatMode = mode; synchronizeEngineQueue(); save() }
    func enqueue(_ items: [PlaybackItem], next: Bool) {
        guard !playingFromMusic else {
            onError(MapleError(status: 0, message: "Playing from Music — stop it to change your Maple queue.")); return
        }
        queue.enqueue(items, next: next); synchronizeEngineQueue(reload: true); save()
    }
    func moveUpcoming(from offsets: IndexSet, to destination: Int) { guard !playingFromMusic else { return }; queue.moveUpcoming(from: offsets, to: destination); synchronizeEngineQueue(reload: true); save() }
    func removeEntries(_ ids: Set<UUID>) {
        guard !playingFromMusic else { return }
        if let id = queue.currentID, ids.contains(id) { stop() }
        queue.remove(ids); synchronizeEngineQueue(reload: true); save()
    }
    func removeLibraryTracks(_ ids: Set<UUID>) {
        if !playingFromMusic, (currentItem?.libraryID ?? queue.current?.item.libraryID).map(ids.contains) == true { stop() }
        if playingFromMusic, parked?.item?.libraryID.map(ids.contains) == true {
            parked?.item = nil; parked?.position = 0; parked?.duration = 0; parked?.artwork = nil
        }
        queue.removeLibraryTracks(ids); synchronizeEngineQueue(reload: true); save()
    }
    private func synchronizeEngineQueue(reload: Bool = false) {
        guard !playingFromMusic, (currentItem ?? queue.current?.item)?.source == .appleMusic, !deferredRestore else { return }
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
            playing: isPlaying, position: deferredRestore ? position.seconds : engine.position, playbackRate: engine.rate)
    }
    func sample() {
        guard currentItem != nil, isPlaying, !isLoading, !deferredRestore else { return }
        let nextPosition = engine.position
        // Music.app can repeat one queue entry without changing its entry ID or playback status.
        // Reuse the cheap position sample to recognize that boundary; explicit Maple seeks update
        // position immediately and therefore cannot look like a natural wrap on the next sample.
        let repeatsCurrent = !playingFromMusic && (queue.repeatMode == .one || (queue.repeatMode == .all && queue.entries.count == 1))
        if currentItem?.source == .appleMusic, repeatsCurrent, isPlaying, engine.isPlaying,
           duration > 4, position.seconds >= duration - 2, nextPosition <= 2 {
            endPlay(completed: true); playID = UUID()
            reconcile(); publish(); save()
        } else {
            settleListening()
            position.seconds = nextPosition
        }
        savePositionIfDue()
    }
    func refresh() {
        apple.refresh()
        if adoptExternalPlayback() { return }
        reconcile(); publish()
    }
    /// External playback is a transient presentation beside Maple's queue and checkpoint.
    @discardableResult private func adoptExternalPlayback() -> Bool {
        guard !isLoading else { return false }
        if let state = apple.externalPlayback() {
            // A stale Music notification must not stop newly started, audible local playback.
            let replacingOwnedMusic = currentItem?.source == .appleMusic && !deferredRestore
            guard playingFromMusic || ((apple.isPlaying || replacingOwnedMusic) && !(currentItem?.source == .local && (wantsPlayback || local.isPlaying))) else { return false }
            if !playingFromMusic {
                let savedPosition = position.seconds
                parked = ParkedPlayback(item: currentItem, position: savedPosition, duration: duration,
                                        artwork: artworkData, playID: playID)
                endPlay(completed: false)
                local.pause()
                deferredRestore = false
            }
            if externalOccurrence != state.occurrence || currentItem != state.item {
                generation += 1; artworkTask?.cancel()
                currentItem = state.item; externalOccurrence = state.occurrence
                playID = UUID(); artworkData = nil; duration = state.item.duration
                loadArtwork(state.item, ticket: generation)
            }
            reconcile(); publish()
            return true
        }
        if playingFromMusic {
            leaveExternalPlayback(); publishStop(); publish()
            return true
        }
        return false
    }
    private func leaveExternalPlayback() {
        guard playingFromMusic else { return }
        generation += 1; artworkTask?.cancel(); externalOccurrence = nil
        currentItem = parked?.item; duration = parked?.duration ?? 0
        position.seconds = parked?.position ?? 0; artworkData = parked?.artwork
        playID = parked?.playID ?? UUID(); parked = nil
        deferredRestore = currentItem != nil; isPlaying = false; started = false; listenedAt = nil
        synchronizeSampling(); stateChanged()
    }
    private func reconcile() {
        guard currentItem != nil, !isLoading, !deferredRestore else { return }
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
        synchronizeSampling()
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
        if case .unavailableEntries(let ids) = event {
            guard source == .appleMusic, !playingFromMusic else { return }
            let removed = ids.intersection(queue.entries.map(\.id))
            guard !removed.isEmpty else { return }
            queue.remove(removed); save()
            onError(MapleError(status: 0, message: "Unavailable Apple Music queue entries were skipped."))
            return
        }
        if case .loadingProgress(let progress) = event {
            if isLoading, queue.current?.item.source == source { loadingProgress = progress }
            return
        }
        guard !isLoading else { return }
        switch event {
        case .loadingProgress, .unavailableEntries: break
        case .itemChanged(let item, let occurrence, let queueEntryID):
            guard source == .appleMusic else { return }
            if queueEntryID == nil { _ = adoptExternalPlayback(); return }
            guard !playingFromMusic, currentItem?.source == .appleMusic, externalOccurrence != occurrence else { return }
            externalOccurrence = occurrence
            if let queueEntryID { queue.select(queueEntryID) }
            // Music.app can move its system queue independently of Maple.
            endPlay(completed: false); currentItem = item; playID = UUID(); artworkData = nil
            loadArtwork(item, ticket: generation); reconcile(); publish(); save()
        case .stateChanged:
            if source == .appleMusic, adoptExternalPlayback() { return }
            guard currentItem?.source == source else { return }
            reconcile(); publish()
        case .stopped:
            guard source == .appleMusic, currentItem?.source == .appleMusic, !playingFromMusic else { return }
            // Do not copy the system's reset/foreign stopped position into Maple's checkpoint.
            settleListening(); wantsPlayback = false; isPlaying = false; listenedAt = nil
            deferredRestore = true; synchronizeSampling(); publish(); save()
        case .ended:
            if source == .appleMusic, playingFromMusic { _ = adoptExternalPlayback(); return }
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
        guard !playingFromMusic, let persistence else { return }
        let key = UUID(); checkpointKey = key; positionSavedAt = clock()
        let value = PlaybackCheckpoint(queue: queue, position: currentItem == nil ? 0 : (deferredRestore ? position.seconds : engine.position), positionKey: key)
        let previous = saving
        saving = Task { [weak self] in
            await previous?.value
            do { try await persistence.save(value) } catch { self?.onError(error) }
        }
    }
    private func savePositionIfDue() {
        guard !playingFromMusic, let persistence, let key = checkpointKey, clock() - positionSavedAt >= 30 else { return }
        positionSavedAt = clock()
        let seconds = position.seconds, previous = saving
        saving = Task { [weak self] in
            await previous?.value
            do { try await persistence.savePosition(seconds, key: key) } catch { self?.onError(error) }
        }
    }
    func restore(localItem: (UUID) -> PlaybackItem?) async {
        do {
            if let persistence, let saved = try await persistence.load(), queue.entries.isEmpty {
                queue = saved.queue; checkpointKey = saved.positionKey; positionSavedAt = clock()
                let missing = Set(queue.entries.filter { entry in
                    entry.item.source == .local && entry.item.libraryID.flatMap(localItem) == nil
                }.map(\.id))
                let restoredCurrent = queue.currentID
                queue.remove(missing); queue.rebaseLocalItems(localItem)
                if queue.current == nil, let first = queue.entries.first { queue.select(first.id) }
                // All restore is metadata-only. Audio preparation waits for an explicit Play.
                currentItem = queue.current?.item; deferredRestore = currentItem != nil
                duration = currentItem?.duration ?? 0; position.seconds = queue.currentID == restoredCurrent && currentItem != nil ? max(0, saved.position) : 0
                if let item = currentItem { loadArtwork(item, ticket: generation) }
            }
            refresh()
        } catch { onError(error) }
    }
    func waitForReports() async { await reporting?.value }
    func waitForSave() async { await saving?.value }
    deinit { sampling?.cancel(); artworkTask?.cancel() }
}
