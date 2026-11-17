import Foundation
import Testing
@testable import Maple

@MainActor final class ReviewMusicBackend: AppleMusicBackend {
    var onChange: (() -> Void)?
    var state = AppleMusicPlayerState()
    var installed: [PlaybackEntry] = []
    var prepares = 0
    var plays = 0
    var stops = 0
    var mode = PlaybackRepeat.off
    var preparationGeneration = 0
    let nativePreparation = AppleMusicPreparation()
    var afterAssignment: (() async throws -> Void)?
    var resetsModesOnAssignment = false
    var preparedStatus = AppleMusicPlayerState.Status.paused
    // Hardware may expose the catalog equivalent and a rewritten ID, already during prepare.
    var systemItem: ((PlaybackItem) -> PlaybackItem)?
    var systemEntryID: ((String?) -> String?)?
    var resolve: (([PlaybackEntry], UUID, (Double) -> Void) async throws -> AppleMusicInstallation)?
    func prepare(_ entries: [PlaybackEntry], selected: UUID, progress: (Double) -> Void) async throws -> AppleMusicInstallation {
        prepares += 1; preparationGeneration += 1
        let ticket = preparationGeneration
        let result: AppleMusicInstallation
        if let resolve { result = try await resolve(entries, selected, progress) }
        else { result = AppleMusicInstallation(entries: entries.map { AppleMusicInstalledEntry(entry: $0, identities: $0.item.musicIdentityIDs, systemID: "created:\($0.id)") }) }
        try Task.checkCancellation()
        guard ticket == preparationGeneration else { throw CancellationError() }
        try await nativePreparation.run { [self] in
            try Task.checkCancellation()
            guard ticket == preparationGeneration else { throw CancellationError() }
            installed = result.entries.map(\.entry)
            if resetsModesOnAssignment { mode = .off }
            state = AppleMusicPlayerState(item: entries.first { $0.id == selected }?.item, occurrence: result.entries.first { $0.entry.id == selected }?.systemID, status: preparedStatus)
            if let item = state.item, let systemItem { state.item = systemItem(item) }
            if let systemEntryID { state.occurrence = systemEntryID(state.occurrence) }
            try await afterAssignment?()
        }
        try Task.checkCancellation()
        guard ticket == preparationGeneration else { throw CancellationError() }
        return result
    }
    func cancelPreparation() {
        preparationGeneration += 1
    }
    func configure(repeatMode: PlaybackRepeat) { mode = repeatMode }
    func play() async throws { plays += 1; state.status = .playing; onChange?() }
    func pause() { state.status = .paused; onChange?() }
    func stop() { stops += 1; state.status = .stopped; onChange?() }
    func seek(to seconds: Double) { state.position = seconds }
    func skip(forward: Bool) async throws {}
    func change(_ item: PlaybackItem?, id: String, status: AppleMusicPlayerState.Status, position: Double = 0, notify: Bool = true) {
        state = AppleMusicPlayerState(item: item, occurrence: id, status: status, position: position)
        if notify { onChange?() }
    }
}

@MainActor struct PlaybackReview3Tests {
    private func song(_ id: String, source: PlaybackItem.Source = .appleMusic) -> PlaybackItem {
        var value = PlaybackItem(source: source, id: id, title: id, duration: 180)
        if source == .local { value.libraryID = UUID() }
        return value
    }
    private func player(_ backend: ReviewMusicBackend, local: (any PlaybackEngine)? = nil) -> PlaybackController {
        PlaybackController(local: local ?? PlaybackFakeEngine(), apple: AppleMusicPlaybackEngine(backend: backend), reporter: PlaybackFakeReporter(), automaticSampling: false)
    }
    @Test func wholeSegmentIsReadyBeforePlayAndMidAlbumRepeatKeepsPreviousSongs() async {
        let backend = ReviewMusicBackend(), player = player(backend)
        backend.resetsModesOnAssignment = true
        let songs = (0..<200).map { song(String($0)) }
        await player.start(songs, startingAt: 75)
        #expect(backend.plays == 1); #expect(backend.installed.map(\.item.id) == songs.map(\.id))
        #expect(backend.state.item == songs[75]); #expect(!player.playingFromMusic)
        player.setRepeat(.all); await player.waitForLoad()
        #expect(backend.mode == .all)
        await player.start(songs, startingAt: 75)
        #expect(backend.mode == .all) // fake resets modes at queue assignment
        #expect(backend.installed.first?.item == songs.first)
        backend.change(songs[74], id: "changed-id", status: .playing)
        #expect(player.queue.current?.item == songs[74]); #expect(!player.playingFromMusic)
        let local = song("Local", source: .local)
        await player.start([songs[0], songs[1], local]); player.setRepeat(.all); await player.waitForLoad()
        #expect(backend.mode == .off)
    }
    @Test func bulkRestoreResolvesAllBeforePlayAndWarmBrowsingNeedsNoLookup() async throws {
        var libraryCalls: [[String]] = [], catalogCalls: [[String]] = []
        let resolver = AppleMusicTrackResolver<String>(library: { ids in
            libraryCalls.append(ids)
            return Dictionary(uniqueKeysWithValues: ids.filter { (Int($0.dropFirst(2)) ?? 0) % 2 == 0 }.map { ($0,$0) })
        }, catalog: { ids in
            catalogCalls.append(ids); return Dictionary(uniqueKeysWithValues: ids.map { ($0,$0) })
        })
        let backend = ReviewMusicBackend(), entered = TestGate(), release = TestGate()
        backend.resolve = { entries, selected, progress in
            await entered.open(); await release.wait()
            let resolved = try await resolver.context(entries, selected: selected, progress: progress)
            return AppleMusicInstallation(entries: resolved.values.map { AppleMusicInstalledEntry(entry: $0.0, identities: [$0.1], systemID: nil) }, unavailable: resolved.unavailable)
        }
        let player = player(backend)
        let songs = (0..<250).map { number in
            var item = song("i.\(number)")
            item.appleMusicIdentity = AppleMusicIdentity(libraryID: item.id, catalogID: String(number))
            return item
        }
        let start = Task { await player.start(songs, startingAt: 100) }
        await entered.wait()
        #expect(backend.plays == 0); #expect(player.isLoading)
        await release.open(); await start.value
        #expect(libraryCalls.map(\.count) == [100,100,50]); #expect(catalogCalls.map(\.count) == [50,50,25])
        #expect(backend.installed.count == 250); #expect(backend.plays == 1); #expect(player.loadingProgress == 1)
        await player.start(songs)
        #expect(libraryCalls.count == 3); #expect(catalogCalls.count == 3)
        let browsing = AppleMusicTrackResolver<String>(library: { _ in Issue.record("Warm browsing looked up library"); return [:] }, catalog: { _ in Issue.record("Warm browsing looked up catalog"); return [:] })
        for s in songs { browsing.register(s.id, id: s.id) }
        let entries = songs.map { PlaybackEntry(item: $0) }
        #expect(try await browsing.context(entries, selected: entries[100].id).values.count == 250)
    }
    @Test func rewrittenEntryIDsAndEquivalentSongIDsKeepOwnershipAndChooseNearestDuplicate() async {
        let backend = ReviewMusicBackend(), player = player(backend)
        var a = song("i.A"); a.appleMusicIdentity = AppleMusicIdentity(libraryID: "i.A", catalogID: "123")
        await player.start([a, song("B"), a, song("C")], startingAt: 2)
        backend.change(song("123"), id: "totally-different", status: .playing)
        #expect(!player.playingFromMusic); #expect(player.queue.index == 2)
        backend.change(song("C"), id: "another-id", status: .playing)
        #expect(player.queue.index == 3); #expect(!player.playingFromMusic)
    }
    @Test func silentTakeoverOnForegroundParksPositionAndForeignEndNeverReinstallsMaple() async {
        let backend = ReviewMusicBackend(), player = player(backend)
        await player.start([song("A"),song("B")]); backend.state.position = 42; player.sample()
        backend.change(song("Siri"), id: "foreign", status: .paused, position: 99, notify: false)
        player.refresh()
        #expect(player.playingFromMusic); #expect(player.currentItem?.id == "Siri")
        let prepares = backend.prepares
        backend.change(nil, id: "end", status: .stopped)
        #expect(!player.playingFromMusic); #expect(player.currentItem?.id == "A")
        #expect(player.position.seconds == 42); #expect(!player.isPlaying)
        #expect(backend.prepares == prepares); #expect(backend.plays == 1)
    }
    @Test func pausedExternalCannotReappearOverPausedLocalAndWaitingIntentBlocksAdoption() async {
        let backend = ReviewMusicBackend(), local = PlaybackFakeEngine(), player = player(backend, local: local)
        backend.change(song("Music"), id: "music", status: .playing)
        #expect(player.playingFromMusic)
        await player.start([song("Local", source: .local)])
        // AVPlayer waiting is not playing yet, but the user's start intent still wins.
        local.isPlaying = false
        backend.change(song("Music"), id: "music", status: .playing)
        #expect(!player.playingFromMusic); #expect(player.currentItem?.id == "Local")
        player.pause(); backend.change(song("Music"), id: "music", status: .paused)
        player.refresh()
        #expect(!player.playingFromMusic); #expect(player.currentItem?.id == "Local")
        #expect(!player.isPlaying)
    }
    @Test func preparedStoppedStatusDoesNotAdvanceBeforeActualPlay() async throws {
        let backend = ReviewMusicBackend(); backend.preparedStatus = .stopped
        let entered = TestGate(), release = TestGate()
        backend.resolve = { entries, _, _ in
            await entered.open(); await release.wait()
            return AppleMusicInstallation(entries: entries.map { AppleMusicInstalledEntry(entry: $0, identities: $0.item.musicIdentityIDs, systemID: nil) })
        }
        let engine = AppleMusicPlaybackEngine(backend: backend)
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: engine, reporter: PlaybackFakeReporter(), automaticSampling: false)
        let receive = engine.onEvent; var ended = 0
        engine.onEvent = { event in
            if case .ended = event { ended += 1 }
            receive?(event)
        }
        let start = Task { await player.start([song("A"), song("B")]) }
        await entered.wait(); player.pause(); await release.open(); await start.value
        backend.onChange?()
        await player.waitForLoad()
        #expect(ended == 0)
        #expect(player.queue.index == 0); #expect(backend.prepares == 1); #expect(backend.plays == 0)
    }
    @Test func transientNeighborLookupFailureDefersNeighborAndStartsAvailableAudio() async {
        let backend = ReviewMusicBackend()
        let resolver = AppleMusicTrackResolver<String>(library: { ids in Dictionary(uniqueKeysWithValues: ids.filter { $0 == "A" }.map { ($0,$0) }) }, catalog: { _ in throw URLError(.notConnectedToInternet) })
        backend.resolve = { entries, selected, progress in
            let value = try await resolver.context(entries, selected: selected, progress: progress)
            return AppleMusicInstallation(entries: value.values.map { AppleMusicInstalledEntry(entry: $0.0, identities: [$0.1], systemID: nil) }, unavailable: value.unavailable)
        }
        let player = player(backend)
        await player.start([song("A"),song("offline")])
        #expect(player.queue.entries.map(\.item.id) == ["A","offline"])
        #expect(player.isPlaying); #expect(backend.installed.map(\.item.id) == ["A"]); #expect(backend.plays == 1)
    }
    @Test func externalEnqueueShowsNoticeForBothLibraryActions() {
        let backend = ReviewMusicBackend(), player = player(backend)
        backend.change(song("Music"), id: "external", status: .playing)
        var notices: [String] = []; player.onError = { notices.append($0.localizedDescription) }
        player.enqueue([song("Next")], next: true); player.enqueue([song("Last")], next: false)
        #expect(notices.count == 2); #expect(notices.allSatisfy { $0.contains("Playing from Music") })
        #expect(backend.prepares == 0)
    }
    @Test func selectedMissingSongHasReadableNoticeThroughController() async {
        let backend = ReviewMusicBackend()
        backend.resolve = { _,_,_ in throw AppleMusicResolutionError.notFound }
        let player = player(backend); var notice = ""; player.onError = { notice = $0.localizedDescription }
        await player.start([song("gone")])
        #expect(notice == "This Apple Music track is no longer available.")
    }
}

extension PlaybackReview3Tests {
    @Test(arguments: ["load", "activation", "play", "cancel"])
    func transientLocalFailuresNeverPruneQueue(_ failure: String) async {
        let local = SuspendedPlaybackEngine(), player = player(ReviewMusicBackend(), local: local)
        let songs = ["A","B","C"].map { song($0, source: .local) }
        await player.start(songs)
        var errors = 0; player.onError = { _ in errors += 1 }
        switch failure {
        case "load": local.loadErrors["B"] = URLError(.timedOut)
        case "activation": player.activateAudio = { _ in throw LibraryError.unreadableAudio }
        case "play": local.playError = LibraryError.unreadableAudio
        default: local.loadErrors["B"] = CancellationError()
        }
        await player.next(natural: true)
        #expect(player.queue.entries.map(\.item.id) == ["A","B","C"])
        #expect(player.queue.current?.item.id == "B"); #expect(!player.isPlaying)
        #expect(errors == (failure == "cancel" ? 0 : 1))
    }
    @Test func pauseDuringUnreadableLoadIsKeptForFollowingFile() async {
        let local = SuspendedPlaybackEngine(), player = player(ReviewMusicBackend(), local: local)
        await player.start(["A","B","C"].map { song($0, source: .local) })
        local.loadErrors["B"] = LibraryError.unreadableAudio; local.suspendLoads = true
        let next = Task { await player.next(natural: true) }
        await local.waitForLoad(2); player.pause(); local.release(2)
        await local.waitForLoad(3); local.release(3); await next.value
        #expect(player.currentItem?.id == "C"); #expect(!player.isPlaying)
        #expect(local.plays == 1); #expect(player.queue.entries.map(\.item.id) == ["A","C"])
    }
    @Test func claimedPausedReporterKeepsHeartbeatAndResumeKeepsSamePlay() async throws {
        let socket = FakePlaybackTransport(), sleeper = TestSleeper()
        let reporter = PlaybackReporter(transport: socket, sleep: { try await sleeper.sleep($0) })
        var value = TrackSnapshot(identity: "local:A", title: "A", artist: "", album: "", playing: true, position: 17)
        await reporter.update(value); await sleeper.waitForSleep()
        let id = reporter.playbackId
        value.playing = false; await reporter.update(value)
        try #require(sleeper.cancellationCount.read() == 0)
        // Advance four 25s intervals, exceeding the server lease. Await the next sleep after each send.
        for _ in 0..<4 {
            let sent = TestGate()
            socket.didSend = { event in if event == "playbackUpdate" { Task { await sent.open() } } }
            await sleeper.advance(); await sent.wait(); await sleeper.waitForSleep()
            #expect(socket.events.last?.1.playing == false); #expect(socket.events.last?.1.position == 17)
        }
        value.playing = true; await reporter.update(value)
        #expect(reporter.playbackId == id)
        #expect(socket.events.filter { $0.0 == "playbackStart" }.count == 1)
        await reporter.stop(); await sleeper.waitForNoSleeps()
    }
    @Test func playingPositionUsesFixedSizeSidecarWithoutQueueRewriteAndPausedSamplingIsIdle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("queue"), disk = PlaybackPersistence(url: url)
        let local = PlaybackFakeEngine(); var time = 0.0
        let player = PlaybackController(local: local, apple: PlaybackFakeEngine(), reporter: PlaybackFakeReporter(), persistence: disk, automaticSampling: false, clock: { time })
        await player.start((0..<1000).map { song(String($0), source: .local) }); await player.waitForSave()
        let bytes = try Data(contentsOf: url)
        time = 29; local.position = 29; player.sample(); await player.waitForSave()
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("position").path))
        time = 35; local.position = 35; player.sample(); await player.waitForSave()
        #expect(try Data(contentsOf: url) == bytes)
        let sidecarURL = url.appendingPathExtension("position")
        #expect(try Data(contentsOf: sidecarURL).count == 44)
        #expect(try await disk.load()?.position == 35)
        let restored = PlaybackController(local: PlaybackFakeEngine(), apple: PlaybackFakeEngine(), reporter: PlaybackFakeReporter(), persistence: disk, automaticSampling: false)
        await restored.restore { _ in song("Restored", source: .local) }
        #expect(restored.currentItem != nil)
        #expect(restored.position.seconds == 35); #expect(!restored.isPlaying)
        local.position = 42; player.pause(); await player.waitForSave()
        let sidecar = try Data(contentsOf: sidecarURL), paused = try Data(contentsOf: url)
        time = 1000; local.position = 900; player.sample(); await player.waitForSave()
        #expect(try Data(contentsOf: url) == paused); #expect(try Data(contentsOf: sidecarURL) == sidecar)
        // The pause made a new full checkpoint; the older position sidecar must no longer apply.
        #expect(try await disk.load()?.position == 42)
    }
    @Test func deferredAutomaticResumeDoesNotTakeForeignClaimAndUnknownDurationSeekSurvivesLoad() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = PlaybackPersistence(url: directory.appendingPathComponent("queue"))
        var unknown = song("Unknown"); unknown.duration = 0
        var queue = PlaybackQueue(); queue.replace([unknown], startingAt: 0, shuffle: false)
        try await disk.save(PlaybackCheckpoint(queue: queue, position: 92))
        let socket = FakePlaybackTransport(), reporter = PlaybackReporter(transport: socket, automaticHeartbeat: false)
        let backend = ReviewMusicBackend()
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: AppleMusicPlaybackEngine(backend: backend), reporter: reporter, persistence: disk, automaticSampling: false)
        await player.restore { _ in nil }; await player.waitForReports()
        reporter.ownershipChanged("desktop")
        await player.resume(userInitiated: false); await player.waitForReports()
        #expect(!player.isPlaying); #expect(backend.prepares == 0)
        #expect(player.position.seconds == 92)
        #expect(socket.events.filter { $0.0 == "playbackStart" }.isEmpty)
        player.pause(); await player.waitForReports(); await player.resume(); await player.waitForReports()
        #expect(socket.events.filter { $0.0 == "playbackStart" }.count == 1)
        #expect(backend.state.position == 92)
        player.stop(); await player.waitForReports(); await player.waitForSave()
    }
    @Test func signInRefreshClaimsAlreadyPlayingSnapshotButNeverPaused() async {
        for playing in [false,true] {
            let socket = FakePlaybackTransport(), reporter = PlaybackReporter(transport: socket, automaticHeartbeat: false)
            reporter.snapshotProvider = { TrackSnapshot(identity: "A", title: "A", artist: "", album: "", playing: playing, position: 17) }
            await reporter.connected()
            #expect(socket.events.filter { $0.0 == "playbackStart" }.count == (playing ? 1 : 0))
            await reporter.stop()
        }
    }
}


extension PlaybackReview3Tests {
    @Test(arguments: [false,true])
    func localEngineIdentifiesMissingAndInvalidFilesAsUnreadable(_ exists: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        if exists { try Data("not an audio file".utf8).write(to: url) }
        let engine = LocalPlaybackEngine()
        var item = song("Unreadable", source: .local); item.audioURL = url
        await #expect(throws: LibraryError.self) { try await engine.load(item) }
        #expect(!engine.isPlaying)
    }
}
