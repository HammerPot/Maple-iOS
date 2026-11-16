import Foundation
import Observation

/// Look someone up by username, show who it is, then send a request.
@MainActor @Observable
final class AddFriendModel {
    enum Relationship: Equatable { case me, friend, requestSent, requestReceived, stranger }

    var username = "" {
        didSet { if username != oldValue { found = nil; errorMessage = nil } }
    }
    private(set) var found: Profile?
    private(set) var isSearching = false
    private(set) var isSending = false
    private(set) var errorMessage: String?
    /// Set once a request was sent or accepted, with a confirmation line.
    private(set) var completion: String?

    @ObservationIgnored private let friends: FriendsModel
    @ObservationIgnored private let myID: String?
    @ObservationIgnored private let session: any SessionEnding

    init(friends: FriendsModel, myID: String?, session: any SessionEnding) {
        self.friends = friends; self.myID = myID; self.session = session
    }

    private var trimmed: String { username.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@", with: "", options: .anchored) }
    var canSearch: Bool { !trimmed.isEmpty && !isSearching && !isSending }

    var relationship: Relationship? {
        guard let found else { return nil }
        if found.id == myID { return .me }
        if friends.friends.contains(where: { $0.id == found.id }) { return .friend }
        if friends.requests.outgoing.contains(where: { $0.id == found.id }) { return .requestSent }
        if friends.requests.incoming.contains(where: { $0.id == found.id }) { return .requestReceived }
        return .stranger
    }

    func search() async {
        guard canSearch else { return }
        let name = trimmed
        isSearching = true; errorMessage = nil; found = nil
        defer { isSearching = false }
        do {
            found = try await friends.lookUp(username: name)
        } catch {
            if AccountErrorCopy.status(of: error) == 404 {
                errorMessage = "No one on Maple uses the username “\(name)”. Check the spelling and try again."
            } else {
                errorMessage = AccountErrorCopy.message(for: error)
            }
        }
    }

    func send() async {
        guard let found, relationship == .stranger, !isSending else { return }
        isSending = true; errorMessage = nil; defer { isSending = false }
        do {
            try await friends.sendRequest(to: found)
            completion = "Friend request sent to \(FriendsModel.displayLabel(found))."
        } catch {
            await fail(error)
        }
    }

    func accept() async {
        guard let found, relationship == .requestReceived, !isSending else { return }
        isSending = true; errorMessage = nil; defer { isSending = false }
        do {
            try await friends.accept(id: found.id)
            completion = "You’re now friends with \(FriendsModel.displayLabel(found))."
        } catch {
            await fail(error)
        }
    }

    private func fail(_ error: Error) async {
        if AccountErrorCopy.endsSession(error) { await session.invalidate(); return }
        errorMessage = AccountErrorCopy.message(for: error)
        // A 409 means the lists here are out of date; refresh so the relationship line is right.
        try? await friends.refresh()
    }
}
