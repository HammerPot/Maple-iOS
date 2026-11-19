import Foundation
@testable import Maple

/// Test doubles and fixtures for the account and friends view models. No network, no Keychain.

enum Fixture {
    static func error(_ status: Int, code: String? = nil, message: String? = nil, error: String? = nil) -> MapleError {
        MapleError(status: status, code: code, error: error, message: message)
    }
    static func user(id: String = "me", username: String = "tester", name: String? = "Tester",
                     visibility: ListeningVisibility = .public, listening: Listening = Listening(current: nil, lastPlayed: nil)) -> MapleUser {
        MapleUser(id: id, username: username, name: name, pfp: nil, listeningVisibility: visibility, listening: listening)
    }
    static func current(title: String = "Song", playing: Bool = true, position: Double = 10, rate: Double = 1, duration: Double? = 200) -> CurrentPlayback {
        CurrentPlayback(title: title, artist: "Artist", album: "Album", duration: duration, playing: playing,
                        position: position, playbackRate: rate, artwork: "art")
    }
    static func friend(_ id: String, _ username: String, name: String? = nil, listening: Listening? = Listening(current: nil, lastPlayed: nil)) -> ListeningProfile {
        ListeningProfile(id: id, username: username, name: name, listening: listening)
    }
    static func profile(_ id: String, _ username: String, name: String? = nil) -> Profile { Profile(id: id, username: username, name: name) }
    static func session(_ id: String, token: String, agent: String?, updated: TimeInterval) -> AuthSession {
        let date = Date(timeIntervalSince1970: updated)
        return AuthSession(id: id, token: token, userId: "me", expiresAt: date.addingTimeInterval(86_400), createdAt: date,
                           updatedAt: date, ipAddress: "192.0.2.1", userAgent: agent)
    }
    static func reply(sessionID: String, email: String = "t@example.test") -> SessionReply {
        SessionReply(user: AuthUser(id: "me", name: "Tester", email: email, emailVerified: true, username: "tester"),
                     session: session(sessionID, token: "current-token", agent: nil, updated: 0))
    }
}

/// A controllable clock.
@MainActor final class TestClock {
    var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@MainActor
final class FakeSignInService: SignInService {
    struct EnrollCall: Equatable { let username: String; let password: String; let email: String; let newUsername: String? }
    var signInResults: [Error?] = []
    var signUpError: Error?
    var resendError: Error?
    var enrollResults: [Error?] = []
    var resetError: Error?
    var verifiedResults: [Swift.Result<Bool, Error>] = []
    var passkeyError: Error?

    private(set) var signIns: [(identifier: String, password: String)] = []
    private(set) var signUps: [(username: String, email: String, password: String)] = []
    private(set) var resent: [String] = []
    private(set) var enrollments: [EnrollCall] = []
    private(set) var resets: [String] = []
    private(set) var verifiedChecks = 0
    private(set) var invalidations = 0

    func signIn(identifier: String, password: String) async throws {
        signIns.append((identifier, password))
        if !signInResults.isEmpty, let error = signInResults.removeFirst() { throw error }
    }
    func signUp(username: String, email: String, password: String) async throws {
        signUps.append((username, email, password)); if let signUpError { throw signUpError }
    }
    func resendVerification(email: String) async throws { resent.append(email); if let resendError { throw resendError } }
    func enrollLegacy(username: String, password: String, email: String, newUsername: String?) async throws {
        enrollments.append(EnrollCall(username: username, password: password, email: email, newUsername: newUsername))
        if !enrollResults.isEmpty, let error = enrollResults.removeFirst() { throw error }
    }
    func requestPasswordReset(email: String) async throws { resets.append(email); if let resetError { throw resetError } }
    func refreshIfVerified() async throws -> Bool {
        verifiedChecks += 1
        return verifiedResults.isEmpty ? false : try verifiedResults.removeFirst().get()
    }
    func signInWithPasskey() async throws { if let passkeyError { throw passkeyError } }
    func invalidate() async { invalidations += 1 }
}

@MainActor
final class FakeSecurityService: AccountSecurityService {
    var user: MapleUser? = Fixture.user()
    var currentReply: SessionReply? = Fixture.reply(sessionID: "s-current")
    var sessions: [AuthSession] = []
    var refreshError: Error?
    var changeEmailError: Error?
    var changePasswordError: Error?
    var listError: Error?
    var revokeError: Error?
    var deleteError: Error?
    var everywhereError: Error?

    private(set) var refreshes = 0
    private(set) var changedEmails: [String] = []
    private(set) var passwordChanges: [(current: String, new: String, revoke: Bool)] = []
    private(set) var revokedTokens: [String] = []
    private(set) var signedOutEverywhere = 0
    private(set) var deletions = 0
    private(set) var invalidations = 0
    var onRefresh: (() -> Void)?

    func refresh() async throws { refreshes += 1; if let refreshError { throw refreshError }; onRefresh?() }
    func currentSession() async throws -> SessionReply? { currentReply }
    func changeEmail(_ email: String) async throws { changedEmails.append(email); if let changeEmailError { throw changeEmailError } }
    func changePassword(current: String, new: String, revokeOtherSessions: Bool) async throws {
        passwordChanges.append((current, new, revokeOtherSessions)); if let changePasswordError { throw changePasswordError }
    }
    func listSessions() async throws -> [AuthSession] { if let listError { throw listError }; return sessions }
    func revokeSession(token: String) async throws { revokedTokens.append(token); if let revokeError { throw revokeError } }
    func signOut() async throws { await invalidate() }
    func signOutEverywhere() async throws { signedOutEverywhere += 1; if let everywhereError { throw everywhereError } }
    func deleteAccount() async throws { deletions += 1; if let deleteError { throw deleteError } }
    func invalidate() async { invalidations += 1; user = nil }
}

actor FakeProfileAPI: AccountProfileService {
    var nameError: Error?
    var visibilityError: Error?
    var avatarError: Error?
    private(set) var names: [String] = []
    private(set) var visibilities: [ListeningVisibility] = []
    private(set) var avatars = 0
    func fail(name: Error? = nil, visibility: Error? = nil, avatar: Error? = nil) {
        nameError = name; visibilityError = visibility; avatarError = avatar
    }
    func setDisplayName(_ name: String) async throws { names.append(name); if let nameError { throw nameError } }
    func setListeningVisibility(_ visibility: ListeningVisibility) async throws {
        visibilities.append(visibility); if let visibilityError { throw visibilityError }
    }
    func setAvatar(_ data: Data) async throws { avatars += 1; if let avatarError { throw avatarError } }
}

actor FakeFriendsService: FriendsService {
    var friendList: [ListeningProfile] = []
    var requestList = FriendRequests()
    var profiles: [String: Profile] = [:]
    var failure: Error?
    var refreshFailure: Error?
    private(set) var sent: [String] = []
    private(set) var accepted: [String] = []
    private(set) var declined: [String] = []
    private(set) var removed: [String] = []

    func set(friends: [ListeningProfile]? = nil, requests: FriendRequests? = nil, profiles: [String: Profile]? = nil) {
        if let friends { friendList = friends }; if let requests { requestList = requests }; if let profiles { self.profiles = profiles }
    }
    func fail(_ error: Error?) { failure = error }
    func failRefresh(_ error: Error?) { refreshFailure = error }

    func friends() async throws -> [ListeningProfile] { if let refreshFailure { throw refreshFailure }; return friendList }
    func requests() async throws -> FriendRequests { if let refreshFailure { throw refreshFailure }; return requestList }
    func profile(username: String) async throws -> Profile {
        guard let profile = profiles[username.lowercased()] else { throw Fixture.error(404, error: "User not found") }
        return profile
    }
    func sendRequest(id: String) async throws {
        if let failure { throw failure }
        sent.append(id)
        if let profile = profiles.values.first(where: { $0.id == id }) { requestList.outgoing.append(profile) }
    }
    func acceptRequest(id: String) async throws {
        if let failure { throw failure }
        accepted.append(id)
        if let profile = requestList.incoming.first(where: { $0.id == id }) {
            requestList.incoming.removeAll { $0.id == id }
            friendList.append(ListeningProfile(id: profile.id, username: profile.username, name: profile.name, listening: nil))
        }
    }
    func declineOrCancelRequest(id: String) async throws {
        if let failure { throw failure }
        declined.append(id); requestList.incoming.removeAll { $0.id == id }; requestList.outgoing.removeAll { $0.id == id }
    }
    func removeFriend(id: String) async throws {
        if let failure { throw failure }
        removed.append(id); friendList.removeAll { $0.id == id }
    }
}

@MainActor
final class FakePasskeyService: PasskeyService {
    var items: [PasskeyItem] = []
    private(set) var registered = 0
    private(set) var invalidations = 0
    func passkeys() async throws -> [PasskeyItem] { items }
    func registerPasskey(name: String?) async throws { registered += 1 }
    func deletePasskey(id: String) async throws { items.removeAll { $0.id == id } }
    func renamePasskey(id: String, name: String) async throws {}
    func invalidate() async { invalidations += 1 }
}

@MainActor
final class SessionEndRecorder: SessionEnding {
    private(set) var invalidations = 0
    func invalidate() async { invalidations += 1 }
}
