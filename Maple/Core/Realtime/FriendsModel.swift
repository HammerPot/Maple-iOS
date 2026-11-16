import Foundation
import Observation

@MainActor @Observable
final class FriendsModel {
    private(set) var friends: [ListeningProfile] = []
    private(set) var requests = FriendRequests()
    private(set) var lastEvent: String?
    @ObservationIgnored private let api: MapleAPI
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var eventRevision = 0
    init(api: MapleAPI) { self.api = api }
    func refresh() async throws {
        let version = revision
        let events = eventRevision
        async let friends = api.friends()
        async let requests = api.requests()
        let values = try await (friends, requests)
        guard version == revision else { return }
        // Re-fetch if a live event arrived while these snapshots were in flight.
        guard events == eventRevision else { try await refresh(); return }
        self.friends = values.0; self.requests = values.1
    }
    func listening(_ event: ListeningEvent) {
        eventRevision += 1
        if let index = friends.firstIndex(where: { $0.id == event.id }) { friends[index].listening = event.listening }
    }
    func friendship(_ name: String, event: FriendshipEvent) async throws {
        lastEvent = name; eventRevision += 1
        if name == "friendRemoved" {
            friends.removeAll { $0.id == event.id }
            requests.incoming.removeAll { $0.id == event.id }; requests.outgoing.removeAll { $0.id == event.id }
        }
        try await refresh()
    }
    func sendRequest(username: String) async throws {
        let profile = try await api.profile(username: username)
        try await api.sendRequest(id: profile.id); try await refresh()
    }
    func accept(id: String) async throws { try await api.acceptRequest(id: id); try await refresh() }
    func declineOrCancel(id: String) async throws { try await api.declineOrCancelRequest(id: id); try await refresh() }
    func remove(id: String) async throws { try await api.removeFriend(id: id); try await refresh() }
    func clear() { revision += 1; friends = []; requests = FriendRequests() }
}
