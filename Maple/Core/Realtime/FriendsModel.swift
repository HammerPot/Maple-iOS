import Foundation
import Observation

/// The friend routes `FriendsModel` needs. `MapleAPI` is the production implementation; tests substitute a fake.
protocol FriendsService: Sendable {
    func friends() async throws -> [ListeningProfile]
    func requests() async throws -> FriendRequests
    func profile(username: String) async throws -> Profile
    func sendRequest(id: String) async throws
    func acceptRequest(id: String) async throws
    func declineOrCancelRequest(id: String) async throws
    func removeFriend(id: String) async throws
}
extension MapleAPI: FriendsService {}

/// A user-facing announcement for a realtime friendship event. `acceptRequestID` is set for incoming requests
/// so the presenter can offer an Accept action.
struct FriendNotice: Equatable, Sendable {
    let message: String
    var acceptRequestID: String? = nil
}

@MainActor @Observable
final class FriendsModel {
    private(set) var friends: [ListeningProfile] = []
    private(set) var requests = FriendRequests()
    private(set) var lastEvent: String?
    /// True once a refresh has succeeded for the current account, so screens can tell "loading" from "empty".
    private(set) var hasLoaded = false
    /// When each friend's `listening.current.position` was true, for local progress extrapolation.
    private(set) var listeningReceivedAt: [String: Date] = [:]
    /// Called after a realtime friendship event has been applied. The composition root presents it.
    @ObservationIgnored var announce: ((FriendNotice) -> Void)?
    @ObservationIgnored private let service: any FriendsService
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var eventRevision = 0

    convenience init(api: MapleAPI) { self.init(service: api) }
    init(service: any FriendsService, clock: @escaping () -> Date = Date.init) {
        self.service = service; self.clock = clock
    }

    func refresh() async throws {
        let version = revision
        let events = eventRevision
        async let friends = service.friends()
        async let requests = service.requests()
        let values = try await (friends, requests)
        guard version == revision else { return }
        // Re-fetch if a live event arrived while these snapshots were in flight.
        guard events == eventRevision else { try await refresh(); return }
        let now = clock()
        self.friends = values.0; self.requests = values.1
        listeningReceivedAt = Dictionary(values.0.map { ($0.id, now) }, uniquingKeysWith: { first, _ in first })
        hasLoaded = true
    }
    func listening(_ event: ListeningEvent) {
        eventRevision += 1
        if let index = friends.firstIndex(where: { $0.id == event.id }) {
            friends[index].listening = event.listening
            listeningReceivedAt[event.id] = clock()
        }
    }
    func friendship(_ name: String, event: FriendshipEvent) async throws {
        lastEvent = name; eventRevision += 1
        if name == "friendRemoved" {
            friends.removeAll { $0.id == event.id }
            requests.incoming.removeAll { $0.id == event.id }; requests.outgoing.removeAll { $0.id == event.id }
            listeningReceivedAt[event.id] = nil
        }
        try await refresh()
        if let notice = notice(for: name, id: event.id) { announce?(notice) }
    }
    /// Copy for a realtime event, using the lists as they are after the event was applied.
    func notice(for name: String, id: String) -> FriendNotice? {
        let profile = requests.incoming.first { $0.id == id } ?? friends.first { $0.id == id }?.profile
            ?? requests.outgoing.first { $0.id == id }
        let who = profile.map(Self.displayLabel)
        switch name {
        case "friendRequest":
            guard requests.incoming.contains(where: { $0.id == id }) else { return nil }
            return FriendNotice(message: "\(who ?? "Someone") sent you a friend request.", acceptRequestID: id)
        case "requestAccepted":
            return FriendNotice(message: who.map { "\($0) accepted your friend request." } ?? "Your friend request was accepted.")
        case "acceptedRequest":
            return FriendNotice(message: who.map { "You’re now friends with \($0)." } ?? "You have a new friend.")
        default:
            return nil
        }
    }
    /// "Display Name (@username)", or "@username" when there is no separate display name.
    static func displayLabel(_ profile: Profile) -> String {
        profile.label == profile.username ? "@" + profile.username : "\(profile.label) (@\(profile.username))"
    }
    func friend(id: String) -> ListeningProfile? { friends.first { $0.id == id } }

    func lookUp(username: String) async throws -> Profile { try await service.profile(username: username) }
    func sendRequest(username: String) async throws {
        let profile = try await service.profile(username: username)
        try await sendRequest(to: profile)
    }
    func sendRequest(to profile: Profile) async throws { try await service.sendRequest(id: profile.id); try await refresh() }
    func accept(id: String) async throws { try await service.acceptRequest(id: id); try await refresh() }
    func declineOrCancel(id: String) async throws { try await service.declineOrCancelRequest(id: id); try await refresh() }
    func remove(id: String) async throws { try await service.removeFriend(id: id); try await refresh() }
    func clear() {
        revision += 1; friends = []; requests = FriendRequests()
        hasLoaded = false; listeningReceivedAt = [:]
    }
}
