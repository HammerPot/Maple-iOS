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
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
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
        generation += 1
        let ticket = generation
        local.stop(); apple.stop()
        currentItem = nil; isPlaying = false; isLoading = true; listenedAt = nil
        artworkData = nil; artworkTask?.cancel()
        position.seconds = 0; duration = 0; started = false; playID = UUID()
        guard let item = queue.current?.item else { isLoading = false; return }
        let target = item.source == .local ? local : apple
        do {
            try await target.load(item)
            guard generation == ticket else { return }
            currentItem = item
            duration = target.duration > 0 ? target.duration : item.duration
            if seconds > 0 { await target.seek(to: min(seconds, max(0, duration))) }
            guard generation == ticket else { return }
            position.seconds = target.position; isLoading = false
            loadArtwork(item, ticket: ticket)
            if autoplay {
                try activateAudio(item.source)
                try await target.play()
                guard generation == ticket else { return }
            }
            reconcile()
            publish(userInitiated: autoplay)
            save()
        } catch {
            guard generation == ticket else { return }
            target.stop(); currentItem = nil; isPlaying = false; isLoading = false
            duration = 0; position.seconds = 0; started = false
            publishStop(); stateChanged(); save()
            if !(error is CancellationError) { onError(error) }
        }
    }
    func resume() async {
        guard currentItem != nil else { await loadCurrent(autoplay: true); return }
        do {
            try activateAudio(currentItem?.source ?? .local)
            try await engine.play()
            reconcile(); publish(userInitiated: true)
        } catch { onError(error) }
    }
    func pause() {
        settleListening(); engine.pause(); isPlaying = false; listenedAt = nil
        position.seconds = engine.position; publish(); save()
    }
    func stop() {
        generation += 1; endPlay(completed: false)
        local.stop(); apple.stop(); artworkTask?.cancel()
        currentItem = nil; artworkData = nil; isPlaying = false; isLoading = false
        position.seconds = 0; duration = 0
        publishStop(); stateChanged(); save()
    }
    func next(natural: Bool = false) async {
        endPlay(completed: natural)
        if queue.advance(natural: natural) { await loadCurrent(autoplay: true) }
        else { stop() }
    }
    func previous() async {
        if engine.position > 3 || !queue.previous() { await seek(to: 0); return }
        endPlay(completed: false); await loadCurrent(autoplay: true)
    }
    /// Called once on release, by a lyric line or by a remote command, never per slider tick.
    func seek(to seconds: Double) async {
        guard currentItem != nil, seconds.isFinite else { return }
        settleListening(); listenedAt = nil
        let ticket = generation
        await engine.seek(to: min(max(0, seconds), max(0, duration)))
        guard ticket == generation else { return }
        position.seconds = engine.position; listenedAt = isPlaying ? clock() : nil
        publish(); save()
    }
    func setShuffle(_ enabled: Bool) { queue.setShuffle(enabled); save() }
    func setRepeat(_ mode: PlaybackRepeat) { queue.repeatMode = mode; save() }
    func enqueue(_ items: [PlaybackItem], next: Bool) { queue.enqueue(items, next: next); save() }
    func moveUpcoming(from offsets: IndexSet, to destination: Int) { queue.moveUpcoming(from: offsets, to: destination); save() }
    func removeEntries(_ ids: Set<UUID>) {
        if let id = queue.currentID, ids.contains(id) { stop() }
        queue.remove(ids); save()
    }
    func removeLibraryTracks(_ ids: Set<UUID>) {
        if currentItem?.libraryID.map(ids.contains) == true { stop() }
        queue.removeLibraryTracks(ids); save()
    }
    var snapshot: TrackSnapshot? {
        guard let item = currentItem else { return nil }
        return TrackSnapshot(identity: "\(item.source == .local ? "local" : "apple"):\(item.id):\(playID)",
            title: item.title, artist: item.artist, album: item.album, duration: duration,
            playing: isPlaying, position: engine.position, playbackRate: engine.rate)
    }
    func sample() {
        guard currentItem != nil, !isLoading else { return }
        settleListening()
        position.seconds = engine.position
        ticks += 1
        if ticks % 10 == 0 { save() }
    }
    func refresh() { reconcile(); publish() }
    private func reconcile() {
        guard currentItem != nil, !isLoading else { return }
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
        case .itemChanged(let item, let occurrence):
            guard source == .appleMusic, currentItem?.source == .appleMusic, externalOccurrence != occurrence else { return }
            externalOccurrence = occurrence
            // Music.app can move its system queue independently of Maple.
            endPlay(completed: false); currentItem = item; playID = UUID(); artworkData = nil
            loadArtwork(item, ticket: generation); reconcile(); publish(); save()
        case .stateChanged:
            guard currentItem?.source == source else { return }
            reconcile(); publish()
        case .ended:
            guard currentItem?.source == source else { return }
            Task { await next(natural: true) }
        case .failed(let error):
            guard currentItem?.source == source else { return }
            stop(); onError(error)
        }
    }
    private func publish(userInitiated: Bool = false) {
        stateChanged()
        guard let value = snapshot else { return }
        let previous = reporting; let reporter = reporter; let data = artworkData
        reporting = Task {
            await previous?.value
            await reporter.update(value, artwork: data, force: true)
            if userInitiated { await reporter.playbackStarted() }
        }
    }
    private func publishStop() {
        let previous = reporting; let reporter = reporter
        reporting = Task { await previous?.value; await reporter.stop() }
    }
    private func loadArtwork(_ item: PlaybackItem, ticket: Int) {
        guard let url = item.artworkURL else { return }
        artworkTask = Task { [weak self] in
            let data = await self?.artworkLoader.read(url)
            guard let self, self.generation == ticket, self.currentItem?.id == item.id, !Task.isCancelled else { return }
            self.artworkData = data; self.stateChanged()

        }
    }
    func artworkForClaim() async -> Data? {
        guard let item = currentItem, let url = item.artworkURL else { return nil }
        return await artworkLoader.read(url)
    }
    func save() {
        guard let persistence else { return }
        let value = PlaybackCheckpoint(queue: queue, position: currentItem == nil ? 0 : engine.position)
        let previous = saving
        saving = Task { [weak self] in
            await previous?.value
            do { try await persistence.save(value) } catch { self?.onError(error) }
        }
    }
    func restore(localItem: (UUID) -> PlaybackItem?) async {
        guard let persistence else { return }
        do {
            guard let saved = try await persistence.load(), currentItem == nil, queue.entries.isEmpty else { return }
            queue = saved.queue
            let missing = Set(queue.entries.filter { entry in
                entry.item.source == .local && entry.item.libraryID.flatMap(localItem) == nil
            }.map(\.id))
            queue.remove(missing)
            // Rebase local URLs after reinstall/container changes, keeping occurrence IDs and order.
            var refreshed = queue
            refreshed.rebaseLocalItems(localItem)
            queue = refreshed
            await loadCurrent(autoplay: false, at: saved.position)
        } catch { onError(error) }
    }
    func waitForReports() async { await reporting?.value }
    func waitForSave() async { await saving?.value }
    deinit { sampling?.cancel(); artworkTask?.cancel() }
}
