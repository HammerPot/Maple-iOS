import Foundation
import Observation

@MainActor @Observable
final class FriendsModel {
    private(set) var friends: [ListeningProfile] = []
    private(set) var requests = FriendRequests()
    private(set) var lastEvent: String?
    @ObservationIgnored private let api: MapleAPI
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var listeningUpdates: [String: ListeningEvent] = [:]
    @ObservationIgnored private var refreshRevision = 0
    init(api: MapleAPI) { self.api = api }
    func refresh() async throws {
        let version = revision
        refreshRevision += 1
        let refresh = refreshRevision
        // Listening events that arrive while this request is in flight are newer than its response and are laid
        // over it. Older ones are not, or an event cached before a socket outage would mask fresher server state.
        listeningUpdates = [:]
        async let friends = api.friends()
        async let requests = api.requests()
        let values = try await (friends, requests)
        // Every friendship event starts its own refresh, which supersedes this snapshot. Listening events never
        // invalidate it (the in-place update and overlay cover them), so a busy friend cannot make this loop.
        guard version == revision, refresh == refreshRevision else { return }
        self.friends = values.0.map { profile in
            var profile = profile
            if let event = listeningUpdates[profile.id] { profile.listening = event.listening }
            return profile
        }
        self.requests = values.1
        listeningUpdates = [:]
    }
    func listening(_ event: ListeningEvent) {
        listeningUpdates[event.id] = event
        if let index = friends.firstIndex(where: { $0.id == event.id }) { friends[index].listening = event.listening }
    }
    func friendship(_ name: String, event: FriendshipEvent) async throws {
        lastEvent = name
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
    func clear() { revision += 1; friends = []; requests = FriendRequests(); lastEvent = nil; listeningUpdates = [:] }
}
