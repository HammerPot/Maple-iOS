import Foundation
import Observation
import OSLog

/// Loading, error and action state for the Friends screens on top of the shared `FriendsModel`.
@MainActor @Observable
final class FriendsScreenModel {
    private(set) var isLoading = false
    /// Shown full-screen when nothing has loaded yet.
    private(set) var loadError: String?
    /// IDs with an accept/decline/cancel/remove in flight.
    private(set) var pending: Set<String> = []

    let friends: FriendsModel
    @ObservationIgnored private let session: any SessionEnding
    @ObservationIgnored private let report: @MainActor (String) -> Void
    @ObservationIgnored private let logger = Logger(subsystem: "dev.hammerpot.Maple-iOS", category: "Friends")

    init(friends: FriendsModel, session: any SessionEnding, report: @escaping @MainActor (String) -> Void) {
        self.friends = friends; self.session = session; self.report = report
    }

    /// Friends currently playing or paused on a track, then everyone else; each group alphabetical.
    var listeningNow: [ListeningProfile] { friends.friends.filter { $0.listening?.current != nil }.sorted(by: Self.byName) }
    var others: [ListeningProfile] { friends.friends.filter { $0.listening?.current == nil }.sorted(by: Self.byName) }
    var incomingCount: Int { friends.requests.incoming.count }
    var outgoingCount: Int { friends.requests.outgoing.count }
    var hasRequests: Bool { incomingCount + outgoingCount > 0 }
    var showsEmptyState: Bool { friends.hasLoaded && friends.friends.isEmpty }

    func receivedAt(_ id: String) -> Date { friends.listeningReceivedAt[id] ?? .now }

    func load() async {
        guard !isLoading else { return }
        isLoading = true; defer { isLoading = false }
        do {
            try await friends.refresh()
            loadError = nil
        } catch {
            guard await handleSessionEnd(error) == false else { return }
            let message = AccountErrorCopy.message(for: error) ?? AccountErrorCopy.generic
            logger.error("Friends refresh failed: status \(AccountErrorCopy.status(of: error) ?? 0, privacy: .public)")
            if friends.hasLoaded { report(message) } else { loadError = message }
        }
    }

    func accept(_ profile: Profile) async {
        await perform(profile.id) { try await self.friends.accept(id: profile.id) }
    }
    func decline(_ profile: Profile) async {
        await perform(profile.id) { try await self.friends.declineOrCancel(id: profile.id) }
    }
    func cancel(_ profile: Profile) async {
        await perform(profile.id) { try await self.friends.declineOrCancel(id: profile.id) }
    }
    func remove(_ profile: Profile) async {
        await perform(profile.id, success: "You removed \(FriendsModel.displayLabel(profile)) as a friend.") {
            try await self.friends.remove(id: profile.id)
        }
    }

    private func perform(_ id: String, success: String? = nil, _ action: () async throws -> Void) async {
        guard !pending.contains(id) else { return }
        pending.insert(id); defer { pending.remove(id) }
        do {
            try await action()
            if let success { report(success) }
        } catch {
            guard await handleSessionEnd(error) == false else { return }
            if let message = AccountErrorCopy.message(for: error) { report(message) }
            // The lists may be stale (e.g. "request not found"); resync quietly.
            try? await friends.refresh()
        }
    }

    /// Any 401 here means the session is gone.
    private func handleSessionEnd(_ error: Error) async -> Bool {
        guard AccountErrorCopy.endsSession(error) else { return false }
        await session.invalidate()
        return true
    }

    private static func byName(_ a: ListeningProfile, _ b: ListeningProfile) -> Bool {
        a.profile.label.localizedStandardCompare(b.profile.label) == .orderedAscending
    }
}
