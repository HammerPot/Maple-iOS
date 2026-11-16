import Foundation

/// Narrow, fakeable views of `AuthSessionModel` and `MapleAPI` for the account view models.

@MainActor protocol SessionEnding: AnyObject {
    /// Clears the local session and returns the app to signed-out.
    func invalidate() async
}

@MainActor protocol SignInService: SessionEnding {
    func signIn(identifier: String, password: String) async throws
    func signUp(username: String, email: String, password: String) async throws
    func resendVerification(email: String) async throws
    func enrollLegacy(username: String, password: String, email: String, newUsername: String?) async throws
    func requestPasswordReset(email: String) async throws
    func refreshIfVerified() async throws -> Bool
    func signInWithPasskey() async throws
}

@MainActor protocol AccountSecurityService: SessionEnding {
    var user: MapleUser? { get }
    func refresh() async throws
    func currentSession() async throws -> SessionReply?
    func changeEmail(_ email: String) async throws
    func changePassword(current: String, new: String, revokeOtherSessions: Bool) async throws
    func listSessions() async throws -> [AuthSession]
    func revokeSession(token: String) async throws
    func signOut() async throws
    func signOutEverywhere() async throws
    func deleteAccount() async throws
}

struct PasskeyItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String?
    let createdAt: Date
    var displayName: String { name?.trimmingCharacters(in: .whitespaces).isEmpty == false ? name ?? "Passkey" : "Passkey" }
}

@MainActor protocol PasskeyService: SessionEnding {
    func passkeys() async throws -> [PasskeyItem]
    func registerPasskey(name: String?) async throws
    func deletePasskey(id: String) async throws
    func renamePasskey(id: String, name: String) async throws
}

extension AuthSessionModel: SignInService, AccountSecurityService, PasskeyService {
    func passkeys() async throws -> [PasskeyItem] {
        try await listPasskeys().map { PasskeyItem(id: $0.id, name: $0.name, createdAt: $0.createdAt) }
    }
}

/// Profile mutations from `MapleAPI`.
protocol AccountProfileService: Sendable {
    func setDisplayName(_ name: String) async throws
    func setListeningVisibility(_ visibility: ListeningVisibility) async throws
    func setAvatar(_ data: Data) async throws
}
extension MapleAPI: AccountProfileService {}
