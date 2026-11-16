import Foundation
import Testing
@testable import Maple

struct FriendsListeningClockTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func playingAdvancesAtPlaybackRate() {
        let clock = ListeningClock(position: 10, duration: 200, playbackRate: 1.5, playing: true, receivedAt: start)
        #expect(clock.elapsed(at: start) == 10)
        #expect(clock.elapsed(at: start.addingTimeInterval(4)) == 16)
        #expect(clock.fraction(at: start.addingTimeInterval(4)) == 0.08)
        #expect(clock.remaining(at: start.addingTimeInterval(4)) == 184)
    }

    @Test func pausedHoldsPosition() {
        let clock = ListeningClock(position: 42, duration: 200, playbackRate: 1, playing: false, receivedAt: start)
        #expect(clock.elapsed(at: start.addingTimeInterval(600)) == 42)
        #expect(!clock.hasEnded(at: start.addingTimeInterval(600)))
    }

    @Test func clampsToDurationAndReportsEnd() {
        let clock = ListeningClock(position: 195, duration: 200, playbackRate: 1, playing: true, receivedAt: start)
        #expect(clock.elapsed(at: start.addingTimeInterval(60)) == 200)
        #expect(clock.fraction(at: start.addingTimeInterval(60)) == 1)
        #expect(clock.hasEnded(at: start.addingTimeInterval(60)))
        #expect(!clock.hasEnded(at: start.addingTimeInterval(1)))
    }

    @Test func unknownDurationHasNoFraction() {
        let clock = ListeningClock(position: 5, duration: nil, playbackRate: 1, playing: true, receivedAt: start)
        #expect(clock.fraction(at: start) == nil && clock.remaining(at: start) == nil)
        #expect(clock.elapsed(at: start.addingTimeInterval(10)) == 15)
        #expect(ListeningClock(position: 5, duration: 0, playbackRate: 1, playing: true, receivedAt: start).knownDuration == nil)
    }

    @Test func badInputsAreSafe() {
        let backwards = ListeningClock(position: 30, duration: 100, playbackRate: 1, playing: true, receivedAt: start)
        #expect(backwards.elapsed(at: start.addingTimeInterval(-20)) == 30, "A clock skew never moves backwards")
        let nan = ListeningClock(position: .nan, duration: .infinity, playbackRate: .nan, playing: true, receivedAt: start)
        #expect(nan.elapsed(at: start.addingTimeInterval(3)) == 3, "Non-finite position starts at 0; bad rate means 1×")
        #expect(nan.knownDuration == nil)
        let negative = ListeningClock(position: -5, duration: 100, playbackRate: -2, playing: true, receivedAt: start)
        #expect(negative.elapsed(at: start.addingTimeInterval(2)) == 0)
        let fast = ListeningClock(position: 0, duration: nil, playbackRate: 100, playing: true, receivedAt: start)
        #expect(fast.elapsed(at: start.addingTimeInterval(1)) == 16, "Rate is capped at the server maximum")
    }

    @Test func statusReflectsPrivacyAndHistory() {
        #expect(ListeningStatus(nil) == .hidden)
        #expect(ListeningStatus(Listening(current: nil, lastPlayed: nil)) == .nothing)
        let last = LastPlayed(title: "Old", artist: "", album: "", duration: nil, playedAt: start, artwork: "a1")
        #expect(ListeningStatus(Listening(current: nil, lastPlayed: last)) == .lastPlayed(last))
        let current = Fixture.current()
        #expect(ListeningStatus(Listening(current: current, lastPlayed: last)) == .current(current))
        #expect(ListeningStatus(Listening(current: nil, lastPlayed: last)).artworkID == "a1")
    }

    @Test func accessibilityDescribesListening() {
        let paused = ListeningStatus(Listening(current: Fixture.current(playing: false, position: 62, duration: 220), lastPlayed: nil))
        #expect(ListeningAccessibility.label(paused, receivedAt: start, now: start.addingTimeInterval(100)) == "Paused Song by Artist, 1:02 of 3:40")
        #expect(ListeningAccessibility.label(.hidden, receivedAt: start) == nil)
    }

    @Test func artworkURLEscapesSegments() throws {
        let url = try #require(MapleAPI.artworkURL(userID: "user id", artwork: "a/b"))
        #expect(url.absoluteString == "https://api.maple.music/public/get/albumArt/user%20id/a%2Fb")
    }
}
