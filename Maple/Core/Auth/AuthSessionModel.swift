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
    /// True when a stored session exists but the server could not be reached (offline, 5xx, captive portal).
    /// `isRestoring` stays true and the Keychain session is kept; the model retries with backoff and on
    /// `sceneBecameActive()`. UIs should show "Couldn't reach Maple" rather than a sign-in form while this is set.
    private(set) var sessionUnreachable = false
    @ObservationIgnored let client: BetterAuthClient
    @ObservationIgnored let api: MapleAPI
    @ObservationIgnored var didChange: (() -> Void)?
    private var revision = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private let retryDelays: [Duration]
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    private var retryGeneration = 0
    var user: MapleUser? { if case .signedIn(let user) = state { return user }; return nil }

    init(api: MapleAPI, retryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(30), .seconds(60)],
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.api = api
        self.retryDelays = retryDelays
        self.sleep = sleep
        client = BetterAuthClient(baseURL: MapleHTTP.baseURL, scheme: "maple", plugins: [UsernamePlugin(), PasskeyPlugin()], httpClient: BetterAuthHTTP(http: api.http))
        // The pre-5.0 cookie and user ID cannot authenticate a Better Auth session.
        UserDefaults.standard.removeObject(forKey: "savedCookies")
        UserDefaults.standard.removeObject(forKey: "savedServerID")
        HTTPCookieStorage.shared.cookies?.filter { $0.domain.contains("maple.music") }.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        api.http.unauthorized.set { [weak self] token in await self?.handleUnauthorized(token: token) }
    }
    func restore() async {
        defer { isRestoring = sessionUnreachable }
        guard api.http.sessionToken != nil else { isRestoring = false; return }
        await attemptRestore()
    }
    /// Only a 401 (or `get-session` returning null) means the session is gone. Anything else, 403 included,
    /// is treated as "could not verify" and keeps the stored session.
    private func attemptRestore() async {
        let version = revision
        do {
            try await refresh()
        }
        catch let error as MapleError where error.status == 401 { await invalidate() }
        catch {
            guard version == revision, !Task.isCancelled, !api.http.sessionCookies.isEmpty else { return }
            sessionUnreachable = true; isRestoring = true
            scheduleRetry()
        }
    }
    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryGeneration += 1
        let generation = retryGeneration
        let delays = retryDelays
        let sleep = sleep
        retryTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                let delay = delays.isEmpty ? Duration.seconds(60) : delays[min(attempt, delays.count - 1)]
                do { try await sleep(delay) } catch { break }
                guard !Task.isCancelled, self?.sessionUnreachable == true else { break }
                attempt += 1
                await self?.attemptRestore()
                if self?.sessionUnreachable != true { break }
            }
            if self?.retryGeneration == generation { self?.retryTask = nil }
        }
    }
    private func cancelRetry() {
        stopRetryTask(); sessionUnreachable = false
    }
    private func stopRetryTask() { retryGeneration += 1; retryTask?.cancel(); retryTask = nil }
    /// The server gave a definite answer, so the stored session is no longer "unverified".
    private func sessionResolved() {
        if sessionUnreachable { stopRetryTask() }
        sessionUnreachable = false; isRestoring = false
    }
    /// Retry an unverified stored session now (a "Try again" button). The flag stays set while the attempt runs,
    /// so the UI does not flicker back to a sign-in form; a failure restarts the backoff.
    func retryRestore() async {
        guard sessionUnreachable else { return }
        stopRetryTask()
        await attemptRestore()
    }
    /// Retry an unverified stored session immediately on foreground.
    func sceneBecameActive() async { await retryRestore() }
    /// A 401 invalidates restoring sessions too. A late response cannot invalidate a new account.
    func handleUnauthorized(token: String? = nil) async {
        if let token, api.http.sessionToken != token { return }
        await invalidate()
    }
    func refresh() async throws {
        let version = revision
        let session: SessionReply? = try await api.http.request("api/auth/get-session")
        guard version == revision else { return }
        guard let session else { await invalidate(); return }
        guard session.user.emailVerified else { sessionResolved(); state = .needsEmailVerification; didChange?(); return }
        let user = try await api.me()
        guard version == revision else { return }
        sessionResolved()
        state = .signedIn(user); didChange?()
    }
    func receiveListening(_ event: ListeningEvent) {
        guard var user = user, user.id == event.id, let listening = event.listening else { return }
        user.listening = listening
        state = .signedIn(user)
    }
    func signIn(identifier: String, password: String) async throws {
        revision += 1
        cancelRetry()
        needsLegacyEnrollment = false
        do {
            // Same rule as the web client: only a valid email address uses the email route.
            if AccountRules.isEmail(identifier) {
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
    /// Clear local state before the best-effort, bounded server request, using only the old session cookie.
    func signOut() async throws {
        let cookies = api.http.sessionCookies
        await invalidate()
        await api.http.revokeSession(cookies: cookies)
    }
    func deleteAccount() async throws { try await api.deleteAccount(); await invalidate() }
    func invalidate() async {
        revision += 1
        cancelRetry()
        api.http.clearCookies()
        state = .signedOut; isRestoring = false; didChange?()
    }
    deinit { retryTask?.cancel() }
    func registerPasskey(name: String? = nil) async throws {
        let ceremony = MaplePasskeyCeremony()
        try await ceremony.register(client: client, name: name)
    }
    func signInWithPasskey() async throws {
        let ceremony = MaplePasskeyCeremony()
        try await ceremony.signIn(client: client)
        try await refresh()
    }
    // MARK: Account feature additions

    /// Side-effect-free check used by the verification-pending screen. Unlike `refresh()`, a missing session
    /// does not sign out or notify; it only transitions when a verified session actually exists.
    func refreshIfVerified() async throws -> Bool {
        let session: SessionReply? = try await api.http.request("api/auth/get-session")
        guard let session, session.user.emailVerified else { return false }
        try await refresh()
        return user != nil
    }
    /// The current Better Auth session and its user (email, session ID for the "this device" marker).
    func currentSession() async throws -> SessionReply? { try await api.http.request("api/auth/get-session") }
    /// Revokes every session including this one (Better Auth `/revoke-sessions`, as the web client's
    /// "Sign out everywhere"), then clears local state. A follow-up `/sign-out` would only fail.
    func signOutEverywhere() async throws {
        _ = try await client.revokeSessions()
        await invalidate()
    }
    func listPasskeys() async throws -> [PasskeyModel] { try await client.passkey.listUserPasskeys().data }
    func deletePasskey(id: String) async throws { _ = try await client.passkey.deletePasskey(with: .init(id: id)) }
    func renamePasskey(id: String, name: String) async throws { _ = try await client.passkey.updatePasskey(with: .init(id: id, name: name)) }
}
