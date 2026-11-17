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
    /// Password changes in flight. While one runs, the server ends the session the old cookie names and replaces it,
    /// so a `get-session` made with the old cookie says nothing about whether the account is still signed in.
    private var credentialChanges = 0
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
        catch let error as MapleError where error.status == 401 {
            guard version == revision, credentialChanges == 0 else { return }
            await invalidate()
        }
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
        guard credentialChanges == 0 else { return }
        if let token, let current = api.http.sessionToken, current != token { return }
        await invalidate()
    }
    func refresh() async throws {
        if credentialChanges > 0 { throw MapleError(status: 0, code: "SESSION_CHANGING", message: "Your session is being updated. Try again in a moment.") }
        let version = revision
        let token = api.http.sessionToken
        let session: SessionReply?
        do { session = try await api.http.request("api/auth/get-session") }
        catch {
            // A request begun before a credential replacement may fail while the old session is being deleted.
            guard version == revision, credentialChanges == 0 else {
                throw MapleError(status: 0, code: "SESSION_CHANGING", message: "Your session is being updated. Try again in a moment.")
            }
            throw error
        }
        guard version == revision else { return }
        guard let session else {
            // `null` answers the cookie that was sent. If a different session replaced it meanwhile
            // (password change, new sign-in), the reply says nothing about the new one.
            if let current = api.http.sessionToken, current != token { return }
            await invalidate(); return
        }
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
                let _: SignInReply = try await post("api/auth/sign-in/email", AuthRequest.SignInEmail(email: identifier, password: password))
            } else {
                let _: SignInReply = try await post("api/auth/sign-in/username", AuthRequest.SignInUsername(username: identifier, password: password))
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
        // The server answers `{"token": null, "user": {…}}` (no session until the email is verified).
        let _: SignUpReply = try await post("api/auth/sign-up/email", AuthRequest.SignUp(email: email, password: password, name: username, username: username))
        state = .needsEmailVerification; didChange?()
    }
    func resendVerification(email: String) async throws {
        let _: StatusReply = try await post("api/auth/send-verification-email", AuthRequest.SendVerification(email: email, callbackURL: "https://play.maple.music"))
    }
    func enrollLegacy(username: String, password: String, email: String, newUsername: String? = nil) async throws {
        let _: StatusReply = try await post("api/auth/legacy/enroll", AuthRequest.LegacyEnrollment(username: username, password: password, email: email, newUsername: newUsername))
        needsLegacyEnrollment = false; state = .needsEmailVerification; didChange?()
    }
    func requestPasswordReset(email: String) async throws {
        let _: StatusReply = try await post("api/auth/request-password-reset", AuthRequest.PasswordReset(email: email, redirectTo: "https://play.maple.music/reset-password"))
    }
    /// The server answers `{"status": true}` only (no `message`) and emails the new address.
    func changeEmail(_ email: String) async throws {
        let _: StatusReply = try await post("api/auth/change-email", AuthRequest.ChangeEmail(newEmail: email, callbackURL: "https://play.maple.music"))
    }
    func changePassword(current: String, new: String, revokeOtherSessions: Bool = true) async throws {
        revision += 1 // Discard refreshes already in flight with the old session.
        credentialChanges += 1
        await api.http.invalidatePendingSessionResponses()
        let before = api.http.sessionToken
        do {
            let _: ChangePasswordReply = try await post("api/auth/change-password", AuthRequest.ChangePassword(currentPassword: current, newPassword: new, revokeOtherSessions: revokeOtherSessions))
        } catch { credentialChanges -= 1; throw error }
        credentialChanges -= 1
        // Revoking the other sessions also ends this one on the server, which answers with a replacement cookie.
        // Tell the app so the realtime connection stops presenting the old one.
        if api.http.sessionToken != before { didChange?() }
    }
    func listSessions() async throws -> [AuthSession] { try await api.http.request("api/auth/list-sessions") }
    func listAccounts() async throws -> [LinkedAccount] { try await api.http.request("api/auth/list-accounts") }
    func revokeSession(token: String) async throws {
        let _: StatusReply = try await post("api/auth/revoke-session", AuthRequest.RevokeSession(token: token))
        try await refresh()
    }
    func revokeOtherSessions() async throws { let _: StatusReply = try await post("api/auth/revoke-other-sessions", AuthRequest.Empty()) }
    private func post<Body: Encodable, Reply: Decodable & Sendable>(_ path: String, _ body: Body) async throws -> Reply {
        try await api.http.request(path, method: "POST", body: JSONEncoder().encode(body))
    }
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
        let version = revision
        let session: SessionReply? = try await api.http.request("api/auth/get-session")
        guard version == revision, let session, session.user.emailVerified else { return false }
        try await refresh()
        return user != nil
    }
    /// The current Better Auth session and its user (email, session ID for the "this device" marker).
    func currentSession() async throws -> SessionReply? { try await api.http.request("api/auth/get-session") }
    /// Clear locally first, then revoke every session with the captured cookie and a bounded request.
    func signOutEverywhere() async throws {
        let cookies = api.http.sessionCookies
        await invalidate()
        try await api.http.revokeCapturedSession(cookies: cookies, everywhere: true)
    }
    func listPasskeys() async throws -> [PasskeyModel] { try await client.passkey.listUserPasskeys().data }
    func deletePasskey(id: String) async throws { _ = try await client.passkey.deletePasskey(with: .init(id: id)) }
    func renamePasskey(id: String, name: String) async throws { _ = try await client.passkey.updatePasskey(with: .init(id: id, name: name)) }
}
