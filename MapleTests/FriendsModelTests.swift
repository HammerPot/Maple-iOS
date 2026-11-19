import Foundation
import Testing
@testable import Maple

@MainActor
struct FriendsModelTests {
    private let ada = Fixture.friend("ada", "ada", name: "Ada", listening: Listening(current: Fixture.current(), lastPlayed: nil))
    private let bob = Fixture.friend("bob", "bob")

    private func loaded(_ service: FakeFriendsService, clock: TestClock) async throws -> FriendsModel {
        let model = FriendsModel(service: service, clock: { clock.now })
        try await model.refresh()
        return model
    }

    @Test func refreshLoadsListsAndStampsListening() async throws {
        let service = FakeFriendsService(); let clock = TestClock()
        await service.set(friends: [ada, bob], requests: FriendRequests(incoming: [Fixture.profile("cy", "cy")], outgoing: []))
        let model = FriendsModel(service: service, clock: { clock.now })
        #expect(!model.hasLoaded)
        try await model.refresh()
        #expect(model.hasLoaded)
        #expect(model.friends.map(\.id) == ["ada", "bob"])
        #expect(model.requests.incoming.map(\.id) == ["cy"])
        #expect(model.listeningReceivedAt["ada"] == clock.now)
    }

    @Test func listeningEventPatchesOneFriendAndRestampsIt() async throws {
        let service = FakeFriendsService(); let clock = TestClock()
        await service.set(friends: [ada, bob])
        let model = try await loaded(service, clock: clock)
        clock.advance(30)
        let paused = Listening(current: Fixture.current(title: "Other", playing: false, position: 42), lastPlayed: nil)
        model.listening(ListeningEvent(id: "bob", listening: paused))
        #expect(model.friend(id: "bob")?.listening == paused)
        #expect(model.listeningReceivedAt["bob"] == clock.now)
        #expect(model.listeningReceivedAt["ada"] == clock.now.addingTimeInterval(-30))
        model.listening(ListeningEvent(id: "ada", listening: nil))
        #expect(model.friend(id: "ada")?.listening == nil, "Going private clears what is shown")
        model.listening(ListeningEvent(id: "stranger", listening: paused))
        #expect(model.friends.count == 2, "Events for non-friends (including yourself) are ignored")
    }

    @Test func friendRequestEventAnnouncesWithAccept() async throws {
        let service = FakeFriendsService(); let clock = TestClock()
        let model = try await loaded(service, clock: clock)
        var notices: [FriendNotice] = []
        model.announce = { notices.append($0) }
        await service.set(requests: FriendRequests(incoming: [Fixture.profile("cy", "cyd", name: "Cyd")], outgoing: []))
        try await model.friendship("friendRequest", event: FriendshipEvent(id: "cy", message: nil))
        #expect(model.requests.incoming.map(\.id) == ["cy"])
        #expect(notices == [FriendNotice(message: "Cyd (@cyd) sent you a friend request.", acceptRequestID: "cy")])
    }

    @Test func acceptanceEventsAnnounceTheNewFriend() async throws {
        let service = FakeFriendsService(); let clock = TestClock()
        await service.set(requests: FriendRequests(incoming: [], outgoing: [Fixture.profile("dee", "dee")]))
        let model = try await loaded(service, clock: clock)
        var notices: [FriendNotice] = []
        model.announce = { notices.append($0) }
        await service.set(friends: [Fixture.friend("dee", "dee")], requests: FriendRequests())
        try await model.friendship("requestAccepted", event: FriendshipEvent(id: "dee", message: "accepted"))
        #expect(model.friends.map(\.id) == ["dee"] && model.requests.outgoing.isEmpty)
        try await model.friendship("acceptedRequest", event: FriendshipEvent(id: "dee", message: nil))
        #expect(notices.map(\.message) == ["@dee accepted your friend request.", "You’re now friends with @dee."])
        #expect(notices.allSatisfy { $0.acceptRequestID == nil })
    }

    @Test func friendRemovedDropsEverywhereWithoutAnnouncing() async throws {
        let service = FakeFriendsService(); let clock = TestClock()
        await service.set(friends: [ada, bob])
        let model = try await loaded(service, clock: clock)
        var notices: [FriendNotice] = []
        model.announce = { notices.append($0) }
        await service.set(friends: [bob])
        try await model.friendship("friendRemoved", event: FriendshipEvent(id: "ada", message: nil))
        #expect(model.friends.map(\.id) == ["bob"])
        #expect(model.listeningReceivedAt["ada"] == nil)
        #expect(notices.isEmpty)
    }

    @Test func clearResetsForAccountChanges() async throws {
        let service = FakeFriendsService(); let clock = TestClock()
        await service.set(friends: [ada])
        let model = try await loaded(service, clock: clock)
        model.clear()
        #expect(model.friends.isEmpty && !model.hasLoaded && model.listeningReceivedAt.isEmpty)
    }

    @Test func displayLabels() {
        #expect(FriendsModel.displayLabel(Fixture.profile("1", "ada", name: "Ada")) == "Ada (@ada)")
        #expect(FriendsModel.displayLabel(Fixture.profile("1", "ada")) == "@ada")
        #expect(FriendsModel.displayLabel(Fixture.profile("1", "ada", name: "")) == "@ada")
    }
}

@MainActor
struct FriendsScreenTests {
    @Test func groupsListeningFriendsFirst() async throws {
        let service = FakeFriendsService()
        await service.set(friends: [
            Fixture.friend("z", "zed", listening: Listening(current: Fixture.current(), lastPlayed: nil)),
            Fixture.friend("b", "bea", listening: nil),
            Fixture.friend("a", "abe"),
            Fixture.friend("y", "yan", listening: Listening(current: Fixture.current(playing: false), lastPlayed: nil)),
        ])
        let model = FriendsScreenModel(friends: FriendsModel(service: service), session: SessionEndRecorder(), report: { _ in })
        await model.load()
        #expect(model.listeningNow.map(\.username) == ["yan", "zed"])
        #expect(model.others.map(\.username) == ["abe", "bea"])
        #expect(!model.showsEmptyState)
    }

    @Test func firstLoadFailureIsFullScreenLaterOnesAreReported() async {
        let service = FakeFriendsService()
        await service.failRefresh(URLError(.notConnectedToInternet))
        var reports: [String] = []
        let model = FriendsScreenModel(friends: FriendsModel(service: service), session: SessionEndRecorder(), report: { reports.append($0) })
        await model.load()
        #expect(model.loadError == "You’re offline. Check your connection and try again.")
        await service.failRefresh(nil)
        await model.load()
        #expect(model.loadError == nil && model.friends.hasLoaded && model.showsEmptyState)
        await service.failRefresh(URLError(.timedOut))
        await model.load()
        #expect(model.loadError == nil)
        #expect(reports == ["Maple took too long to respond. Try again."])
    }

    @Test func unauthorizedReturnsToSignedOut() async {
        let service = FakeFriendsService()
        await service.failRefresh(Fixture.error(401, message: "Unauthorized"))
        let session = SessionEndRecorder()
        var reports: [String] = []
        let model = FriendsScreenModel(friends: FriendsModel(service: service), session: session, report: { reports.append($0) })
        await model.load()
        #expect(session.invalidations == 1)
        #expect(model.loadError == nil && reports.isEmpty, "No error dump; the app just signs out")
    }

    @Test func requestActionsUpdateListsAndReportFailures() async throws {
        let service = FakeFriendsService()
        let cy = Fixture.profile("cy", "cy"), dee = Fixture.profile("dee", "dee")
        await service.set(requests: FriendRequests(incoming: [cy], outgoing: [dee]))
        var reports: [String] = []
        let model = FriendsScreenModel(friends: FriendsModel(service: service), session: SessionEndRecorder(), report: { reports.append($0) })
        await model.load()
        #expect(model.incomingCount == 1 && model.outgoingCount == 1 && model.hasRequests)
        await model.accept(cy)
        #expect(await service.accepted == ["cy"])
        #expect(model.friends.friends.map(\.id) == ["cy"] && model.incomingCount == 0)
        await model.cancel(dee)
        #expect(await service.declined == ["dee"] && !model.hasRequests)

        await service.fail(Fixture.error(404, error: "You are not friends."))
        await model.remove(Fixture.profile("cy", "cy"))
        #expect(reports == ["You’re not friends with this person anymore."])
        #expect(model.pending.isEmpty)

        await service.fail(nil)
        await model.remove(Fixture.profile("cy", "cy"))
        #expect(await service.removed == ["cy"])
        #expect(reports.last == "You removed @cy as a friend.")
    }
}

@MainActor
struct FriendsAddFriendTests {
    private func makeModel(_ service: FakeFriendsService, myID: String = "me") async throws -> (AddFriendModel, FriendsModel) {
        let friends = FriendsModel(service: service)
        try await friends.refresh()
        return (AddFriendModel(friends: friends, myID: myID, session: SessionEndRecorder()), friends)
    }

    @Test func unknownUsernameIsExplained() async throws {
        let (model, _) = try await makeModel(FakeFriendsService())
        model.username = "@nobody "
        await model.search()
        #expect(model.found == nil)
        #expect(model.errorMessage == "No one on Maple uses the username “nobody”. Check the spelling and try again.")
    }

    @Test func lookupShowsWhoItIsThenSends() async throws {
        let service = FakeFriendsService()
        let eve = Fixture.profile("eve", "eve", name: "Eve")
        await service.set(profiles: ["eve": eve])
        let (model, friends) = try await makeModel(service)
        model.username = "Eve"
        await model.search()
        #expect(model.found == eve)
        #expect(model.relationship == .stranger)
        await model.send()
        #expect(await service.sent == ["eve"])
        #expect(friends.requests.outgoing == [eve])
        #expect(model.completion == "Friend request sent to Eve (@eve).")
        #expect(model.relationship == .requestSent)
    }

    @Test func relationshipsPreventPointlessRequests() async throws {
        let service = FakeFriendsService()
        let me = Fixture.profile("me", "tester"), pal = Fixture.profile("pal", "pal"), fan = Fixture.profile("fan", "fan")
        await service.set(friends: [Fixture.friend("pal", "pal")], requests: FriendRequests(incoming: [fan], outgoing: []),
                          profiles: ["tester": me, "pal": pal, "fan": fan])
        let (model, _) = try await makeModel(service)
        model.username = "tester"; await model.search()
        #expect(model.relationship == .me)
        await model.send()
        #expect(await service.sent.isEmpty)
        model.username = "pal"; await model.search()
        #expect(model.relationship == .friend)
        model.username = "fan"; await model.search()
        #expect(model.relationship == .requestReceived)
        await model.accept()
        #expect(await service.accepted == ["fan"])
        #expect(model.completion == "You’re now friends with @fan.")
    }

    @Test func serverConflictsAreReadable() async throws {
        let service = FakeFriendsService()
        await service.set(profiles: ["gus": Fixture.profile("gus", "gus")])
        await service.fail(Fixture.error(409, error: "Friend request already sent."))
        let (model, _) = try await makeModel(service)
        model.username = "gus"; await model.search()
        await model.send()
        #expect(model.errorMessage == "You’ve already sent this person a request.")
        #expect(model.completion == nil)
    }

    @Test func editingTheUsernameClearsTheResult() async throws {
        let service = FakeFriendsService()
        await service.set(profiles: ["gus": Fixture.profile("gus", "gus")])
        let (model, _) = try await makeModel(service)
        model.username = "gus"; await model.search()
        #expect(model.found != nil)
        model.username = "gu"
        #expect(model.found == nil && model.errorMessage == nil)
    }
}
