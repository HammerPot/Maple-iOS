import Foundation
import MusicKit
import Testing
@testable import Maple

@MainActor struct PlaybackDeviceTests {
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
