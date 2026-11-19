import Foundation
import Testing
@testable import Maple

@MainActor struct PlaybackMusicResolutionTests {
    private func item(_ id: String) -> PlaybackItem { PlaybackItem(source: .appleMusic, id: id, title: id) }
    @Test func emptyCacheLegacyCheckpointFallsBackFromLibraryToCatalog() async throws {
        var lookups: [String] = []
        let resolver = AppleMusicTrackResolver<String>(library: { id in lookups += id.map { "library:\($0)" }; return [:] },
            catalog: { id in lookups += id.map { "catalog:\($0)" }; return Dictionary(uniqueKeysWithValues: id.map { ($0, "available") }) })
        // JSON round trip deliberately models the pre-provenance persisted queue format.
        let restored = try JSONDecoder().decode(PlaybackItem.self, from: JSONEncoder().encode(item("12345")))
        #expect(try await resolver.resolve(restored) == "available")
        #expect(lookups == ["library:12345", "catalog:12345"])
    }
    @Test func catalogProvenanceSurvivesPersistenceAndUsesCatalogDirectly() async throws {
        var song = item("12345"); song.appleMusicIdentity = AppleMusicIdentity(catalogID: "12345")
        let restored = try JSONDecoder().decode(PlaybackItem.self, from: JSONEncoder().encode(song))
        var libraryCalls = 0
        let resolver = AppleMusicTrackResolver<String>(library: { _ in libraryCalls += 1; return [:] }, catalog: { Dictionary(uniqueKeysWithValues: $0.map { ($0,$0) }) })
        #expect(try await resolver.resolve(restored) == "12345"); #expect(libraryCalls == 0)
    }
    @Test func unavailableUpcomingDoesNotFailSelectedSongAndRetainsOccurrenceOrder() async throws {
        var lookups: [String] = []
        let resolver = AppleMusicTrackResolver<String>(library: { _ in [:] }, catalog: { id in
            lookups += id; return Dictionary(uniqueKeysWithValues: id.filter { $0 != "missing" }.map { ($0,$0) })
        })
        let previous = PlaybackEntry(item: item("previous")), selected = PlaybackEntry(item: item("selected"))
        let missing = PlaybackEntry(item: item("missing")), next = PlaybackEntry(item: item("next"))
        let restored = try JSONDecoder().decode([PlaybackEntry].self, from: JSONEncoder().encode([previous, selected, missing, next]))
        let result = try await resolver.context(restored, selected: selected.id)
        #expect(Set(lookups) == ["previous", "selected", "missing", "next"])
        #expect(result.values.map { $0.0.id } == [previous.id, selected.id, next.id])
        #expect(result.unavailable == [missing.id])
    }
    @Test func libraryIdentityCanUsePersistedCatalogEquivalentAndSelectedFailureIsVisible() async throws {
        var song = item("i.library"); song.appleMusicIdentity = AppleMusicIdentity(libraryID: "i.library", catalogID: "6789")
        let resolver = AppleMusicTrackResolver<String>(library: { _ in [:] }, catalog: { Dictionary(uniqueKeysWithValues: $0.filter { $0 == "6789" }.map { ($0,"available") }) })
        #expect(try await resolver.resolve(song) == "available")
        let missing = PlaybackEntry(item: item("missing"))
        await #expect(throws: (any Error).self) { try await resolver.context([missing], selected: missing.id) }
    }
}

extension PlaybackMusicResolutionTests {
    @Test func controllerPrunesUnavailableNeighborsAndKeepsSelectedPlayback() async {
        let engine = SuspendedPlaybackEngine()
        engine.unavailableItemIDs = ["missing"]
        let player = PlaybackController(local: PlaybackFakeEngine(), apple: engine, reporter: PlaybackFakeReporter(), automaticSampling: false)
        var notices = 0; player.onError = { _ in notices += 1 }
        await player.start([item("selected"), item("missing"), item("next")])
        #expect(player.currentItem?.id == "selected"); #expect(player.isPlaying)
        #expect(player.queue.entries.map(\.item.id) == ["selected", "next"])
        #expect(notices == 1)
    }
}
