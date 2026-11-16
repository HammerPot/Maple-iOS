import Foundation
import Observation
import BetterAuth
import BetterAuthUsername
import BetterAuthPasskey

@MainActor @Observable
final class AuthSessionModel {
    enum State { case signedOut, needsEmailVerification, signedIn(MapleUser) }
    private(set) var state: State = .signedOut
    private(set) var isRestoring = true
    private(set) var needsLegacyEnrollment = false
    @ObservationIgnored let client: BetterAuthClient
    @ObservationIgnored let api: MapleAPI
    @ObservationIgnored var didChange: (() -> Void)?
    private var revision = 0
    var user: MapleUser? { if case .signedIn(let user) = state { return user }; return nil }

    init(api: MapleAPI) {
        self.api = api
        client = BetterAuthClient(baseURL: MapleHTTP.baseURL, scheme: "maple", plugins: [UsernamePlugin(), PasskeyPlugin()], httpClient: BetterAuthHTTP(http: api.http))
        // The pre-5.0 cookie and user ID cannot authenticate a Better Auth session.
        UserDefaults.standard.removeObject(forKey: "savedCookies")
        UserDefaults.standard.removeObject(forKey: "savedServerID")
        HTTPCookieStorage.shared.cookies?.filter { $0.domain.contains("maple.music") }.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
    }
    func restore() async {
        defer { isRestoring = false }
        do { try await refresh() }
        catch let error as MapleError where error.status == 401 || error.status == 403 { await invalidate() }
        catch { /* Keep the Keychain session for retry after an offline launch. */ }
    }
    func refresh() async throws {
        let version = revision
        let session: SessionReply? = try await api.http.request("api/auth/get-session")
        guard version == revision else { return }
        guard let session else { await invalidate(); return }
        guard session.user.emailVerified else { state = .needsEmailVerification; didChange?(); return }
        let user = try await api.me()
        guard version == revision else { return }
        state = .signedIn(user); didChange?()
    }
    func signIn(identifier: String, password: String) async throws {
        revision += 1
        needsLegacyEnrollment = false
        do {
            if identifier.contains("@") {
                _ = try await client.signIn.email(with: .init(email: identifier, password: password))
            } else {
                _ = try await client.signIn.username(with: .init(username: identifier, password: password))
            }
            try await refresh()
        } catch {
            let normalized = MapleError.normalize(error)
            if let error = normalized as? MapleError {
                if error.code == "EMAIL_NOT_VERIFIED" { state = .needsEmailVerification; didChange?() }
                needsLegacyEnrollment = error.code == "LEGACY_ENROLLMENT_REQUIRED"
            }
            throw normalized
        }
    }
    func signUp(username: String, email: String, password: String) async throws {
        _ = try await client.signUp.email(with: UsernameSignUpEmailRequest(email: email, password: password, name: username, username: username))
        state = .needsEmailVerification; didChange?()
    }
    func resendVerification(email: String) async throws {
        _ = try await client.sendVerificationEmail(with: .init(email: email, callbackURL: "https://play.maple.music"))
    }
    func enrollLegacy(username: String, password: String, email: String, newUsername: String? = nil) async throws {
        struct Enrollment: Encodable { let username: String; let password: String; let email: String; let newUsername: String? }
        let _: StatusReply = try await api.http.request("api/auth/legacy/enroll", method: "POST", body: JSONEncoder().encode(Enrollment(username: username, password: password, email: email, newUsername: newUsername)))
        needsLegacyEnrollment = false; state = .needsEmailVerification; didChange?()
    }
    func requestPasswordReset(email: String) async throws { _ = try await client.requestPasswordReset(with: .init(email: email, redirectTo: "https://play.maple.music/reset-password")) }
    func changeEmail(_ email: String) async throws { _ = try await client.changeEmail(with: .init(newEmail: email, callbackURL: "https://play.maple.music")) }
    func changePassword(current: String, new: String, revokeOtherSessions: Bool = true) async throws {
        _ = try await client.changePassword(with: .init(currentPassword: current, newPassword: new, revokeOtherSessions: revokeOtherSessions))
    }
    func listSessions() async throws -> [AuthSession] { try await api.http.request("api/auth/list-sessions") }
    func listAccounts() async throws -> [LinkedAccount] { try await api.http.request("api/auth/list-accounts") }
    func revokeSession(token: String) async throws { _ = try await client.revokeSession(with: .init(token: token)); try await refresh() }
    func revokeOtherSessions() async throws { _ = try await client.revokeOtherSessions() }
    func signOut() async throws {
        _ = try await client.signOut()
        await invalidate()
    }
    func deleteAccount() async throws { try await api.deleteAccount(); await invalidate() }
    func invalidate() async {
        revision += 1
        await api.http.clearCookies()
        state = .signedOut; didChange?()
    }
    func registerPasskey(name: String? = nil) async throws {
        let ceremony = MaplePasskeyCeremony()
        try await ceremony.register(client: client, name: name)
    }
    func signInWithPasskey() async throws {
        let ceremony = MaplePasskeyCeremony()
        try await ceremony.signIn(client: client)
        try await refresh()
    }
    func listPasskeys() async throws -> [PasskeyModel] { try await client.passkey.listUserPasskeys().data }
    func deletePasskey(id: String) async throws { _ = try await client.passkey.deletePasskey(with: .init(id: id)) }
    func renamePasskey(id: String, name: String) async throws { _ = try await client.passkey.updatePasskey(with: .init(id: id, name: name)) }
}
