import Foundation
import MusicKit
import Testing
@testable import Maple

@MainActor struct PlaybackDeviceTests {
    @Test func cancelledNativePreparationDrainsAndCancelledWaitingInstallIsSkipped() async throws {
        let lane = AppleMusicPreparation(), entered = TestGate(), release = TestGate()
        var calls: [String] = []
        let old = Task {
            try await lane.run {
                calls.append("old assigned")
                await entered.open(); await release.wait() // native call ignores cancellation
                calls.append("old finished")
            }
        }
        await entered.wait(); old.cancel()
        let abandoned = Task { try await lane.run { calls.append("abandoned assigned") } }
        abandoned.cancel()
        let next = Task { try await lane.run { calls.append("new assigned") } }
        // Drain enqueued MainActor jobs (including run's child job) while native A is
        // still suspended. This observes overlap before releasing A, rather than merely
        // hoping the scheduler starts B before the final order assertion.
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        #expect(calls == ["old assigned"])
        await release.open()
        _ = try? await old.value
        do { try await abandoned.value; Issue.record("Cancelled waiting install executed") }
        catch { #expect(error is CancellationError) }
        try await next.value
        #expect(calls == ["old assigned", "old finished", "new assigned"])
    }
    @Test func missingPlaybackParametersNeverReachTheSystemQueueOrPruneMapleEntries() throws {
        let playable = try JSONDecoder().decode(MusicKit.Song.self, from: Data(#"{"id":"i.available","type":"library-songs","attributes":{"name":"Available","artistName":"Artist","playParams":{"id":"i.available","kind":"song","isLibrary":true}}}"#.utf8))
        let unplayable = try JSONDecoder().decode(MusicKit.Song.self, from: Data(#"{"id":"i.unavailable","type":"library-songs","attributes":{"name":"Unavailable","artistName":"Artist"}}"#.utf8))
        let a = PlaybackEntry(item: SystemMusicBackend.item(.song(playable)))
        let b = PlaybackEntry(item: SystemMusicBackend.item(.song(unplayable)))
        let values: [(PlaybackEntry, MusicKit.Track)] = [(a,.song(playable)),(b,.song(unplayable)),(a,.song(playable))]
        let installed = try SystemMusicBackend.playableTracks(values, selected: a.id)
        #expect(installed.map { $0.0.id } == [a.id,a.id])
        #expect(values.map { $0.0.id } == [a.id,b.id,a.id])
        #expect(throws: AppleMusicResolutionError.notPlayable) {
            try SystemMusicBackend.playableTracks(values, selected: b.id)
        }
    }
    @Test func libraryPlaybackParametersPreserveCatalogEquivalentWithoutURL() throws {
        let data = Data(#"{"id":"i.JL1PVeqt89OMq9G","kind":"song","isLibrary":true,"catalogId":"1525933488"}"#.utf8)
        // Exercise MusicKit's Codable boundary, not only our parser.
        let parameters = try JSONDecoder().decode(PlayParameters.self, from: data)
        let encoded = try JSONEncoder().encode(parameters)
        #expect(AppleMusicIdentity.catalogID(url: nil, playParameters: encoded) == "1525933488")
        #expect(AppleMusicIdentity.catalogID(url: URL(string: "https://music.apple.com/us/song/title/1525933488"), playParameters: nil) == "1525933488")
        #expect(AppleMusicIdentity.catalogID(url: URL(string: "https://music.apple.com/us/album/title/1525933486"), playParameters: nil) == nil)
    }
    @Test func rewrittenCatalogSongAndEntryRemainOwnedWithoutDuplicateClaims() async throws {
        let backend = ReviewMusicBackend(), transport = FakePlaybackTransport()
        let reporter = PlaybackReporter(transport: transport, automaticHeartbeat: false)
        var starts = 0; reporter.didStart = { _,_ in starts += 1 }
        backend.systemItem = { item in
            var result = item; result.id = item.appleMusicIdentity?.catalogID ?? item.id
            result.appleMusicIdentity = AppleMusicIdentity(catalogID: result.id)
            return result
        }
        backend.systemEntryID = { _ in "roriBgXeO::NmfmeeEd6" }
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: AppleMusicPlaybackEngine(backend: backend), reporter: reporter, automaticSampling: false)
        let resource = Data(#"{"id":"i.JL1PVeqt89OMq9G","type":"library-songs","attributes":{"name":"Library song","artistName":"Artist","durationInMillis":240000,"playParams":{"id":"i.JL1PVeqt89OMq9G","kind":"song","isLibrary":true,"catalogId":"1525933488"}}}"#.utf8)
        let song = try JSONDecoder().decode(MusicKit.Song.self, from: resource)
        let library = SystemMusicBackend.item(.song(song))
        #expect(library.appleMusicIdentity?.catalogID == "1525933488")
        await player.start([library, library]); await player.waitForReports()
        let occurrence = player.queue.currentID
        #expect(player.isPlaying); #expect(!player.playingFromMusic)
        #expect(player.queue.currentID == occurrence)
        backend.change(backend.state.item, id: "second-native-id", status: .playing, position: 12)
        player.pause(); await player.resume(); await player.waitForReports()
        #expect(!player.playingFromMusic); #expect(player.queue.currentID == occurrence)
        #expect(starts == 1)
        #expect(transport.events.filter { $0.0 == "playbackStart" }.count == 1)
        player.stop(); await player.waitForReports()
    }
}
