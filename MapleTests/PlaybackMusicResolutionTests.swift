import Foundation
import Testing
@testable import Maple

@MainActor struct PlaybackMusicResolutionTests {
    private func item(_ id: String) -> PlaybackItem { PlaybackItem(source: .appleMusic, id: id, title: id) }
    @Test func emptyCacheLegacyCheckpointFallsBackFromLibraryToCatalog() async throws {
        var lookups: [String] = []
        let resolver = AppleMusicTrackResolver<String>(library: { id in lookups.append("library:\(id)"); return nil },
            catalog: { id in lookups.append("catalog:\(id)"); return "available" })
        // JSON round trip deliberately models the pre-provenance persisted queue format.
        let restored = try JSONDecoder().decode(PlaybackItem.self, from: JSONEncoder().encode(item("12345")))
        #expect(try await resolver.resolve(restored) == "available")
        #expect(lookups == ["library:12345", "catalog:12345"])
    }
    @Test func catalogProvenanceSurvivesPersistenceAndUsesCatalogDirectly() async throws {
        var song = item("12345"); song.appleMusicIdentity = AppleMusicIdentity(catalogID: "12345")
        let restored = try JSONDecoder().decode(PlaybackItem.self, from: JSONEncoder().encode(song))
        var libraryCalls = 0
        let resolver = AppleMusicTrackResolver<String>(library: { _ in libraryCalls += 1; return nil }, catalog: { $0 })
        #expect(try await resolver.resolve(restored) == "12345"); #expect(libraryCalls == 0)
    }
    @Test func unavailableUpcomingDoesNotFailSelectedSongAndRetainsOccurrenceOrder() async throws {
        var lookups: [String] = []
        let resolver = AppleMusicTrackResolver<String>(library: { _ in nil }, catalog: { id in
            lookups.append(id); return id == "missing" ? nil : id
        })
        let previous = PlaybackEntry(item: item("previous")), selected = PlaybackEntry(item: item("selected"))
        let missing = PlaybackEntry(item: item("missing")), next = PlaybackEntry(item: item("next"))
        let restored = try JSONDecoder().decode([PlaybackEntry].self, from: JSONEncoder().encode([previous, selected, missing, next]))
        let result = try await resolver.context(restored, selected: selected.id)
        #expect(lookups.first == "selected")
        #expect(result.values.map { $0.0.id } == [selected.id, next.id])
        #expect(result.unavailable == [missing.id])
    }
    @Test func libraryIdentityCanUsePersistedCatalogEquivalentAndSelectedFailureIsVisible() async throws {
        var song = item("i.library"); song.appleMusicIdentity = AppleMusicIdentity(libraryID: "i.library", catalogID: "6789")
        let resolver = AppleMusicTrackResolver<String>(library: { _ in nil }, catalog: { $0 == "6789" ? "available" : nil })
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

extension PlaybackMusicResolutionTests {
    @Test func boundedInitialWindowReturnsBeforeSuspendedTailAndTransientEntriesCanRetry() async throws {
        let entered = TestGate(), release = TestGate()
        var offline = true
        let resolver = AppleMusicTrackResolver<String>(library: { id in
            if id == "11" { await entered.open(); await release.wait() }
            if id == "1" && offline { throw URLError(.notConnectedToInternet) }
            return id
        }, catalog: { _ in nil })
        let entries = (0..<1000).map { PlaybackEntry(item: item(String($0))) }
        let initial = try await resolver.context(entries, selected: entries[0].id)
        #expect(initial.values.first?.0.id == entries[0].id)
        #expect(initial.unavailable.isEmpty); #expect(initial.deferred == [entries[1].id])
        #expect(initial.remaining.count == 989)
        let tail = Task { try await resolver.resolveBatch(Array(initial.remaining.prefix(10))) }
        await entered.wait()
        // Initial entries are already available to install/play even though the tail is still suspended.
        #expect(initial.values.count == 10)
        offline = false
        #expect(try await resolver.resolve(entries[1].item) == "1")
        await release.open(); let appended = try await tail.value
        #expect(appended.values.count == 10)
    }
    @Test func partialSystemContextCannotRepeatAll() {
        var queue = PlaybackQueue(); queue.replace([item("A"), item("B")], startingAt: 0, shuffle: false); queue.repeatMode = .all
        #expect(AppleMusicQueuePolicy.repeatMode(for: queue, installedEntries: [queue.entries[0].id]) == .none)
        #expect(AppleMusicQueuePolicy.repeatMode(for: queue, installedEntries: Set(queue.entries.map(\.id))) == .all)
    }
}
