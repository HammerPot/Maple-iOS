import AVFoundation
import Foundation
import MusicKit
import Testing
@testable import Maple

@MainActor struct PlaybackReview9Tests {
    private func song(_ id: String) -> PlaybackItem { PlaybackItem(source: .appleMusic, id: id, title: id, duration: 180) }
    private func player(_ backend: ReviewMusicBackend, engine: AppleMusicPlaybackEngine? = nil) -> PlaybackController {
        PlaybackController(local: PlaybackFakeEngine(), apple: engine ?? AppleMusicPlaybackEngine(backend: backend), reporter: PlaybackFakeReporter(), automaticSampling: false)
    }
    @Test(arguments: ["next", "previous", "row", "natural", "repeat-one", "repeat-all"])
    func definitiveSelectedFailuresSkipInTravelDirectionWithoutLooping(_ action: String) async {
        let backend = ReviewMusicBackend(), player = player(backend)
        let items = [song("A"),song("missing"),song("B")]
        await player.start(items, startingAt: action == "previous" ? 2 : 0)
        var attempts: [String] = []
        backend.resolve = { entries, selected, _ in
            let selectedEntry = entries.first { $0.id == selected }
            let item = try #require(selectedEntry); attempts.append(item.item.id)
            if item.item.id == "missing" { throw AppleMusicResolutionError.notPlayable }
            return AppleMusicInstallation(entries: entries.filter { $0.item.id != "missing" }.map { AppleMusicInstalledEntry(entry: $0, identities: $0.item.musicIdentityIDs) })
        }
        if action == "previous" { await player.previous() }
        else if action == "row" { await player.playEntry(player.queue.entries[1].id) }
        else {
            if action == "repeat-one" { player.setRepeat(.one); await player.waitForLoad() }
            if action == "repeat-all" { player.setRepeat(.all); await player.waitForLoad() }
            await player.next(natural: action == "natural")
        }
        #expect(attempts == ["missing", action == "previous" ? "A" : "B"])
        #expect(player.queue.entries.map(\.item.id) == ["A","B"])
        #expect(player.currentItem?.id == (action == "previous" ? "A" : "B")); #expect(player.isPlaying)
        player.stop()
    }
    @Test(arguments: [PlaybackRepeat.off, .all, .one])
    func allUnplayableTailEndsCleanlyInOnePass(_ mode: PlaybackRepeat) async {
        let backend = ReviewMusicBackend(), player = player(backend)
        backend.resolve = { _,_,_ in throw AppleMusicResolutionError.notFound }
        player.setRepeat(mode)
        await player.start([song("missing1"), song("missing2"), song("missing3")])
        #expect(backend.prepares == 3); #expect(backend.plays == 0)
        #expect(player.queue.entries.isEmpty); #expect(player.currentItem == nil); #expect(!player.isPlaying)
    }
    @Test func tailDiscoveryPrunesControllerAndCheckpointWithoutReloadOrClaim() async throws {
        let backend = ReviewMusicBackend(), engine = AppleMusicPlaybackEngine(backend: backend), reporter = PlaybackFakeReporter()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let disk = PlaybackPersistence(url: url)
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: engine, reporter: reporter, persistence: disk, automaticSampling: false)
        let items = (0..<120).map { song(String($0)) }
        backend.resolve = { entries, _, _ in
            let missing = Set(entries.filter { ["55","105"].contains($0.item.id) }.map(\.id))
            return AppleMusicInstallation(entries: entries.filter { !missing.contains($0.id) }.map { AppleMusicInstalledEntry(entry: $0, identities: $0.item.musicIdentityIDs) }, unavailable: missing)
        }
        await player.start(items); await engine.waitForExtension(); await player.waitForSave(); await player.waitForReports()
        #expect(player.queue.entries.count == 118)
        #expect(!player.queue.entries.contains { ["55","105"].contains($0.item.id) })
        #expect(try await disk.load()?.queue == player.queue)
        #expect(player.isPlaying); #expect(backend.prepares == 1); #expect(backend.plays == 1); #expect(reporter.starts == 1)
        player.stop()
    }
    @Test func naturalEndAfterAllUnplayableTailStopsWithoutAnotherPrepare() async {
        let backend = ReviewMusicBackend(), engine = AppleMusicPlaybackEngine(backend: backend)
        let player = player(backend, engine: engine), stopped = TestGate()
        let items = (0..<100).map { song(String($0)) }
        backend.resolve = { entries, _, _ in
            let missing = Set(entries.filter { (Int($0.item.id) ?? 0) >= 50 }.map(\.id))
            return AppleMusicInstallation(entries: entries.filter { !missing.contains($0.id) }.map { AppleMusicInstalledEntry(entry: $0, identities: $0.item.musicIdentityIDs) }, unavailable: missing)
        }
        await player.start(items); await engine.waitForExtension()
        #expect(player.queue.entries.count == 50)
        player.stateChanged = { if player.currentItem == nil { Task { await stopped.open() } } }
        backend.change(items[49], id: "final", status: .playing, position: 179)
        backend.change(nil, id: "ended", status: .stopped)
        await stopped.wait()
        #expect(!player.isPlaying); #expect(backend.prepares == 1); #expect(backend.plays == 1)
        #expect(player.currentItem == nil)
    }
    @Test func transientSelectedLookupFailureKeepsOccurrenceForRetry() async {
        let backend = ReviewMusicBackend(), player = player(backend)
        await player.start([song("A"),song("offline"),song("B")])
        let queue = player.queue.entries
        backend.resolve = { _,_,_ in throw URLError(.notConnectedToInternet) }
        await player.next()
        #expect(player.queue.entries == queue); #expect(player.queue.current?.item.id == "offline")
        #expect(!player.isPlaying); #expect(backend.prepares == 2)
        player.stop()
    }
    @Test func stoppedBetweenInstallAndSuspendedPlayNeverRelinquishesOwnership() async {
        let backend = ReviewMusicBackend(), entered = TestGate(), release = TestGate()
        backend.beforePlay = { await entered.open(); await release.wait() }
        let engine = AppleMusicPlaybackEngine(backend: backend), player = player(backend, engine: engine)
        let items = (0..<120).map { song(String($0)) }
        let start = Task { await player.start(items) }
        await entered.wait()
        backend.change(items[0], id: "transient-stop", status: .stopped)
        #expect(player.isLoading)
        await release.open(); await start.value; await engine.waitForExtension()
        #expect(player.isPlaying); #expect(!player.playingFromMusic)
        #expect(backend.installed.count == 120); #expect(backend.appends == 2); #expect(player.queue.index == 0)
        player.stop()
    }
    @Test func interruptionCapturesPlayingIntentBeforeQueuedPlayerStatusReconcile() async throws {
        let local = PlaybackFakeEngine(), player = PlaybackController(local: local, apple: PlaybackFakeEngine(), reporter: PlaybackFakeReporter(), automaticSampling: false)
        let controls = PlaybackSystemControls(); controls.bind(player)
        player.activateAudio = { _ in } // Exercise observer/controller integration without activating hardware audio.
        let resumed = TestGate()
        var item = song("local"); item.source = .local; item.libraryID = UUID()
        await player.start([item])
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: NSNumber(value: AVAudioSession.InterruptionType.began.rawValue)])
        try #require(!player.isPlaying) // The .main observer must execute before returning, with no Task hop.
        // Reconciliation already sees AVPlayer paused before any queued MainActor work runs.
        local.isPlaying = false; local.onEvent?(.stateChanged)
        player.stateChanged = { if player.isPlaying { Task { await resumed.open() } } }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: NSNumber(value: AVAudioSession.InterruptionType.ended.rawValue),
                       AVAudioSessionInterruptionOptionKey: NSNumber(value: AVAudioSession.InterruptionOptions.shouldResume.rawValue)])
        await resumed.wait()
        #expect(player.isPlaying)
        player.stop()
    }
    @Test(arguments: [false, true])
    func restoreMissingCurrentSelectsSurvivorAtZeroOrClearsEmptyQueue(allMissing: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let disk = PlaybackPersistence(url: url), local = PlaybackFakeEngine()
        var missing = song("deleted"), survivor = song("surviving")
        missing.source = .local; missing.libraryID = UUID(); survivor.source = .local; survivor.libraryID = UUID()
        var queue = PlaybackQueue(); queue.replace([missing,survivor], startingAt: 0, shuffle: false)
        try await disk.save(PlaybackCheckpoint(queue: queue, position: 90))
        let player = PlaybackController(local: local, apple: PlaybackFakeEngine(), reporter: PlaybackFakeReporter(), persistence: disk, automaticSampling: false)
        await player.restore { id in !allMissing && id == survivor.libraryID ? survivor : nil }
        #expect(player.position.seconds == 0); #expect(!player.isPlaying); #expect(local.loadCount == 0)
        #expect(player.queue.entries.count == (allMissing ? 0 : 1))
        if !allMissing {
            #expect(player.currentItem?.id == "surviving"); #expect(player.queue.current != nil)
            await player.resume(); #expect(local.loaded?.id == "surviving"); #expect(player.isPlaying)
        } else { #expect(player.currentItem == nil); #expect(player.queue.current == nil) }
        player.stop()
    }
    @Test(arguments: ["suspended-end", "Music-app-stop"])
    func ambiguousFinalIdentityAndIndexCannotAuthorizePlayback(_ history: String) async {
        let backend = ReviewMusicBackend(), player = player(backend)
        await player.start([song("A"),song("final"),PlaybackItem(source: .local, id: "L", title: "L")])
        // Both histories expose identical public state: last final-song sample far from the
        // metadata end, then stopped/reset after a period with no notifications.
        backend.change(song("final"), id: "rewritten", status: .playing, position: 100)
        backend.change(nil, id: "reset", status: .stopped, notify: false)
        player.refresh()
        #expect(!player.isPlaying); #expect(backend.prepares == 1); #expect(backend.plays == 1)
        #expect(player.queue.current?.item.id == "final")
        player.stop()
    }
    @Test func duplicateMusicKitResponseIDsDoNotTrapAndKeepFirstSong() throws {
        func decoded(_ id: String, _ title: String) throws -> MusicKit.Song {
            try JSONDecoder().decode(MusicKit.Song.self, from: JSONSerialization.data(withJSONObject: ["id":id,"type":"library-songs","attributes":["name":title,"artistName":"Artist"]]))
        }
        let first = try decoded("i.same","First"), duplicate = try decoded("i.same","Duplicate"), other = try decoded("i.other","Other")
        let mapped = SystemMusicBackend.songsByID([first,duplicate,other])
        #expect(mapped.count == 2); #expect(mapped["i.same"]?.title == "First"); #expect(mapped["i.other"]?.title == "Other")
    }
}
