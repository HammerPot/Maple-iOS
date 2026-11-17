import Foundation
import Testing
import UIKit
import BetterAuth
import BetterAuthPasskey
@testable import Maple

// Literal replies of the Maple server, fed through the code the app really runs (`AuthSessionModel`, `MapleAPI`,
// the BetterAuthSwift client over `BetterAuthHTTP`). Every fixture names the server source it was derived from.
// Sources: upstream `api/` at 874ac35 and the better-auth 1.7.13 package (`dist/api/routes/*.mjs`,
// `dist/plugins/username/index.mjs`) with `@better-auth/passkey` 1.7.13 and `@simplewebauthn/server` 13.3.2.
// Shapes marked "live" were also captured from api.maple.music with the test account (types only, no values).

enum Wire {
    static let id = "0c1d2e3f4a5b4c6d8e9f0a1b2c3d4e5f"

    /// Better Auth `parseUserOutput` plus the username plugin's `username`/`displayUsername` (live: get-session, sign-in/username).
    static func user(verified: Bool, name: String = "unit", email: String = "unit@example.test") -> String {
        #"{"name":"\#(name)","email":"\#(email)","emailVerified":\#(verified),"image":null,"createdAt":"2026-11-16T10:00:00.000Z","updatedAt":"2026-11-16T10:00:00.000Z","username":"\#(name)","displayUsername":"\#(name)","id":"\#(id)"}"#
    }
    /// api/routes/sign-up.mjs, `shouldSkipAutoSignIn` (Maple sets `requireEmailVerification`): no session, `token` is null.
    static let signUp = #"{"token":null,"user":\#(user(verified: false, name: "newuser", email: "new@example.test"))}"#
    /// The same route for an email that already has an account: `buildGenericDuplicateResponse`, identical shape, no email is sent.
    static let signUpDuplicate = #"{"token":null,"user":\#(user(verified: false, name: "newuser", email: "taken@example.test"))}"#
    /// api/routes/sign-in.mjs and plugins/username/index.mjs (live): Maple's before-hook fills `callbackURL`, so `redirect` is true.
    static let signIn = #"{"redirect":true,"token":"signed-token","url":"https://play.maple.music","user":\#(user(verified: true))}"#
    /// The same replies without a callback URL (a client that sends none and a server without Maple's default).
    static let signInNoRedirect = #"{"redirect":false,"token":"signed-token","user":\#(user(verified: true))}"#
    /// api/routes/session.mjs `parseSessionOutput` (live).
    static let session = #"{"expiresAt":"2026-11-23T10:00:00.000Z","token":"test-session","createdAt":"2026-11-16T10:00:00.000Z","updatedAt":"2026-11-16T10:00:00.000Z","ipAddress":"203.0.113.9","userAgent":"Maple/1 CFNetwork/1 Darwin/24","userId":"\#(id)","id":"session-1"}"#
    static let otherSession = #"{"expiresAt":"2026-11-23T10:00:00.000Z","token":"other-token","createdAt":"2026-11-15T10:00:00.000Z","updatedAt":"2026-11-15T11:00:00.000Z","ipAddress":"","userAgent":"","userId":"\#(id)","id":"session-2"}"#
    /// get-session (live): `{session, user}`; `null` for an unknown or expired cookie.
    static let getSession = #"{"session":\#(session),"user":\#(user(verified: true))}"#
    /// api/routes/session.mjs list-sessions (live).
    static let listSessions = "[\(session),\(otherSession)]"
    /// api/routes/account.mjs list-accounts: `parseAccountOutput` plus `scopes`.
    static let listAccounts = #"[{"id":"acc-1","providerId":"credential","createdAt":"2026-11-01T10:00:00.000Z","updatedAt":"2026-11-01T10:00:00.000Z","accountId":"\#(id)","userId":"\#(id)","scopes":[]}]"#
    /// api/routes/email-verification.mjs, send-verification-email; update-user.mjs change-email; session.mjs revoke-*; password.mjs reset-password.
    static let status = #"{"status":true}"#
    /// api/routes/password.mjs request-password-reset (same reply whether or not the email exists).
    static let passwordReset = #"{"status":true,"message":"If this email exists in our system, check your email for the reset link"}"#
    /// api/routes/update-user.mjs change-password: `token` is null unless `revokeOtherSessions` created a new session.
    static let changePasswordKept = #"{"token":null,"user":\#(user(verified: true))}"#
    static let changePasswordReplaced = #"{"token":"new-token","user":\#(user(verified: true))}"#
    /// api/legacy.ts `ctx.json({ status: true, email: user.email })`.
    static let legacyEnrollment = #"{"status":true,"email":"legacy@example.test"}"#
    /// api/routes/sign-out.mjs `signOutResponse()` (live).
    static let signOut = #"{"success":true}"#
    /// api/get/get.ts → profiles.own + playback.listening (live shape; `pfp` is base64 of the stored image).
    static let me = #"{"id":"\#(id)","username":"unit","name":"unit","pfp":"AQID","listeningVisibility":"public","listening":{"current":null,"lastPlayed":{"title":"Song","artist":"Artist","album":"Album","duration":200,"playedAt":"2026-11-16T09:00:00.000Z","artwork":null}}}"#
    /// An account moved from the pre-5.0 API: `lastPlayed.playedAt` is the old `timePlayed` text
    /// (api/user/profiles.ts `lastPlayed`; api/tests/playback.test.ts "restarting the server keeps last played" asserts `'2020-01-01'`).
    static func meWithLegacyTime(_ playedAt: String) -> String {
        #"{"id":"\#(id)","username":"unit","name":null,"pfp":null,"listeningVisibility":"private","listening":{"current":null,"lastPlayed":{"title":"Old","artist":"Band","album":"LP","duration":null,"playedAt":\#(playedAt),"artwork":null}}}"#
    }
    /// api/user/friends.ts `GET /user/friends/me` (live): `listening` is null for a private friend.
    static let friends = #"[{"id":"f1","username":"ada","name":"Ada","listening":{"current":{"title":"Song","artist":"Artist","album":"Album","duration":null,"playing":true,"position":12.5,"playbackRate":1,"artwork":"art-1"},"lastPlayed":null}},{"id":"f2","username":"bob","name":null,"listening":null}]"#
    static let requests = #"{"incoming":[{"id":"r1","username":"cy","name":null}],"outgoing":[]}"#
    static let message = #"{"message":"Friend request sent."}"#

    // Passkeys: passkey/index.mjs with @simplewebauthn/server 13.3.2 (`generateRegistrationOptions`, `generateAuthenticationOptions`).
    static let passkeyRow = #"{"id":"pk-1","name":null,"publicKey":"pub","userId":"\#(id)","credentialID":"cred-1","counter":0,"deviceType":"multiDevice","backedUp":true,"transports":"","createdAt":"2026-11-10T10:00:00.000Z","aaguid":"fbfc3007-154e-4ecc-8c0b-6e020557d7bd"}"#
    static let passkeyList = "[\(passkeyRow)]"
    static let passkeyUpdate = #"{"passkey":\#(passkeyRow)}"#
    static let passkeyDelete = #"{"status":true}"#
    /// `excludeCredentials[].transports` is `[""]` for a passkey stored without transports (`"".split(",")`).
    static let registerOptions = #"{"challenge":"Y2hhbGxlbmdl","rp":{"name":"Maple","id":"maple.music"},"user":{"id":"dXNlci1pZA","name":"unit@example.test","displayName":"unit@example.test"},"pubKeyCredParams":[{"alg":-8,"type":"public-key"},{"alg":-7,"type":"public-key"},{"alg":-257,"type":"public-key"}],"timeout":60000,"attestation":"none","excludeCredentials":[{"id":"Y3JlZC0x","transports":[""],"type":"public-key"}],"authenticatorSelection":{"residentKey":"preferred","userVerification":"preferred","requireResidentKey":false,"authenticatorAttachment":"platform"},"extensions":{"credProps":true},"hints":[]}"#
    static let authenticateOptions = #"{"rpId":"maple.music","challenge":"Y2hhbGxlbmdl","allowCredentials":[{"id":"Y3JlZC0x","transports":["internal","hybrid"],"type":"public-key"}],"timeout":60000,"userVerification":"preferred"}"#
    static let authenticateOptionsDiscoverable = #"{"rpId":"maple.music","challenge":"Y2hhbGxlbmdl","timeout":60000,"userVerification":"preferred"}"#
    /// verify-authentication returns the raw session row and the user row.
    static let passkeyAuthentication = #"{"session":\#(session),"user":\#(user(verified: true))}"#
}

struct SentRequest: Sendable {
    let method: String
    let path: String
    let origin: String?
    let cookie: String?
    let body: String
    init(_ request: URLRequest) {
        method = request.httpMethod ?? "GET"
        path = request.url?.path ?? ""
        origin = request.value(forHTTPHeaderField: "Origin")
        cookie = request.value(forHTTPHeaderField: "Cookie")
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        body = String(decoding: data, as: UTF8.self)
    }
    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]) ?? [:] }
}

/// A stand-in for api.maple.music: replies by `"METHOD /path"`; anything else is a 404 like the real server's unknown routes.
@MainActor
final class WireHarness {
    typealias Route = @Sendable (CookieStorage) async -> StubReply
    let jar: CookieStorage
    let http: MapleHTTP
    let auth: AuthSessionModel
    let sent: Locked<[SentRequest]>

    init(token: String? = "test-session", routes: [String: Route]) throws {
        let jar = CookieStorage(storage: MemoryCookieStorage())
        if let token { try jar.setCookie("__Secure-maple.session_token=\(token); Path=/; Secure; SameSite=None", for: MapleHTTP.baseURL) }
        let sent = Locked<[SentRequest]>([])
        let http = MapleHTTP(cookies: jar, configuration: StubURLProtocol.configuration { request in
            sent.update { $0.append(SentRequest(request)) }
            guard let route = routes["\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"] else {
                return StubReply(#"{"error":"No such route"}"#, status: 404)
            }
            return await route(jar)
        })
        self.jar = jar; self.http = http; self.sent = sent
        auth = AuthSessionModel(api: MapleAPI(http: http))
    }
    convenience init(token: String? = "test-session", _ routes: [String: StubReply]) throws {
        try self.init(token: token, routes: routes.mapValues { reply -> Route in { _ in reply } })
    }
    func requests(to path: String) -> [SentRequest] { sent.read().filter { $0.path == path } }
}

/// Replies that sign a stored account in: get-session then /get/me.
private let signedInRoutes: [String: StubReply] = [
    "GET /api/auth/get-session": StubReply(Wire.getSession),
    "GET /get/me": StubReply(Wire.me),
]

@MainActor
struct AuthWireDecodingTests {
    // MARK: Registration (H1)

    @Test func signUpReplyWithNullTokenReachesTheVerifyEmailScreen() async throws {
        let h = try WireHarness(token: nil, ["POST /api/auth/sign-up/email": StubReply(Wire.signUp)])
        let register = RegisterModel(session: h.auth)
        register.email = "new@example.test"; register.username = "newuser"; register.password = "Secret123"
        await register.register()
        #expect(register.errorMessage == nil)
        #expect(register.verification?.email == "new@example.test")
        #expect(register.verification?.origin == .register)
        guard case .needsEmailVerification = h.auth.state else { Issue.record("expected the verification state"); return }
        #expect(h.http.sessionToken == nil)
        let request = try #require(h.requests(to: "/api/auth/sign-up/email").first)
        #expect(request.method == "POST"); #expect(request.origin == MapleHTTP.origin)
        #expect(request.json["email"] as? String == "new@example.test")
        #expect(request.json["username"] as? String == "newuser")
        #expect(request.json["name"] as? String == "newuser")
        #expect(request.json["password"] as? String == "Secret123")
    }

    @Test func signUpForAnExistingEmailLooksIdenticalAndAlsoReachesVerification() async throws {
        let h = try WireHarness(token: nil, ["POST /api/auth/sign-up/email": StubReply(Wire.signUpDuplicate)])
        try await h.auth.signUp(username: "newuser", email: "taken@example.test", password: "Secret123")
        guard case .needsEmailVerification = h.auth.state else { Issue.record("expected the verification state"); return }
    }

    @Test func signUpTreatsAnHTMLSuccessPageAsAFailureNotAnAccount() async throws {
        let h = try WireHarness(token: nil, ["POST /api/auth/sign-up/email": StubReply("<html>portal</html>", headers: ["Content-Type": "text/html"])])
        await #expect(throws: DecodingError.self) { try await h.auth.signUp(username: "newuser", email: "new@example.test", password: "Secret123") }
        guard case .signedOut = h.auth.state else { Issue.record("must stay signed out"); return }
    }

    // MARK: Sign-in

    @Test(arguments: [("unit@example.test", "/api/auth/sign-in/email", "email"), ("unit", "/api/auth/sign-in/username", "username")])
    func signInDecodesTheRealReplyForBothRoutes(identifier: String, path: String, key: String) async throws {
        for reply in [Wire.signIn, Wire.signInNoRedirect] {
            var routes = signedInRoutes
            routes["POST " + path] = StubReply(reply)
            let h = try WireHarness(token: nil, routes)
            try await h.auth.signIn(identifier: identifier, password: "Secret123")
            #expect(h.auth.user?.username == "unit")
            let request = try #require(h.requests(to: path).first)
            #expect(request.origin == MapleHTTP.origin)
            #expect(request.json[key] as? String == identifier); #expect(request.json["password"] as? String == "Secret123")
            #expect(h.requests(to: "/api/auth/sign-in/email").count + h.requests(to: "/api/auth/sign-in/username").count == 1)
            await h.auth.invalidate()
        }
    }

    @Test func signInForAnUnverifiedOrLegacyAccountSetsTheRightState() async throws {
        let unverified = try WireHarness(token: nil, ["POST /api/auth/sign-in/username": StubReply(#"{"code":"EMAIL_NOT_VERIFIED","message":"Email not verified"}"#, status: 403)])
        await #expect(throws: MapleError.self) { try await unverified.auth.signIn(identifier: "unit", password: "Secret123") }
        guard case .needsEmailVerification = unverified.auth.state else { Issue.record("expected the verification state"); return }
        // api/auth/auth.ts before-hook.
        let legacy = try WireHarness(token: nil, ["POST /api/auth/sign-in/username": StubReply(#"{"code":"LEGACY_ENROLLMENT_REQUIRED","message":"Add an email address to finish moving your account."}"#, status: 403)])
        await #expect(throws: MapleError.self) { try await legacy.auth.signIn(identifier: "unit", password: "Secret123") }
        #expect(legacy.auth.needsLegacyEnrollment)
    }

    // MARK: Account flows

    @Test func legacyEnrollmentReplyReachesVerification() async throws {
        let h = try WireHarness(token: nil, ["POST /api/auth/legacy/enroll": StubReply(Wire.legacyEnrollment)])
        try await h.auth.enrollLegacy(username: "oldname", password: "Secret123", email: "legacy@example.test", newUsername: nil)
        guard case .needsEmailVerification = h.auth.state else { Issue.record("expected the verification state"); return }
        let request = try #require(h.requests(to: "/api/auth/legacy/enroll").first)
        #expect(request.json["email"] as? String == "legacy@example.test"); #expect(request.json["newUsername"] == nil)
    }

    @Test func statusRepliesDecodeForVerificationResetAndEmailChange() async throws {
        let h = try WireHarness(token: "test-session", [
            "POST /api/auth/send-verification-email": StubReply(Wire.status),
            "POST /api/auth/request-password-reset": StubReply(Wire.passwordReset),
            "POST /api/auth/change-email": StubReply(Wire.status),
        ])
        try await h.auth.resendVerification(email: "unit@example.test")
        try await h.auth.requestPasswordReset(email: "unit@example.test")
        try await h.auth.changeEmail("next@example.test")
        #expect(h.requests(to: "/api/auth/send-verification-email").first?.json["callbackURL"] as? String == "https://play.maple.music")
        #expect(h.requests(to: "/api/auth/request-password-reset").first?.json["redirectTo"] as? String == "https://play.maple.music/reset-password")
        #expect(h.requests(to: "/api/auth/change-email").first?.json["newEmail"] as? String == "next@example.test")
        #expect(h.http.sessionToken == "test-session")
    }

    /// The reviewer's suspicion: Change Email answers `{status: true}` with no `message`, which BetterAuthSwift's type rejects.
    @Test func changeEmailScreenShowsCheckYourEmailForTheRealReply() async throws {
        let h = try WireHarness(token: "test-session", ["POST /api/auth/change-email": StubReply(Wire.status)])
        let model = ChangeEmailModel(currentEmail: "unit@example.test", session: h.auth)
        model.newEmail = "next@example.test"
        await model.submit()
        #expect(model.sentTo == "next@example.test"); #expect(model.error == nil)
    }

    @Test func changePasswordKeepingOtherSessionsLeavesTheCookieAlone() async throws {
        let h = try WireHarness(token: "test-session", ["POST /api/auth/change-password": StubReply(Wire.changePasswordKept)])
        var changes = 0; h.auth.didChange = { changes += 1 }
        try await h.auth.changePassword(current: "OldPass123", new: "NewPass123", revokeOtherSessions: false)
        #expect(h.http.sessionToken == "test-session"); #expect(changes == 0)
        let body = try #require(h.requests(to: "/api/auth/change-password").first).json
        #expect(body["revokeOtherSessions"] as? Bool == false); #expect(body["currentPassword"] as? String == "OldPass123")
    }

    @Test func changePasswordRevokingOthersAdoptsTheReplacementCookieAndNotifies() async throws {
        let replacement: WireHarness.Route = { jar in
            try? jar.setCookie("__Secure-maple.session_token=new-session; Path=/; Max-Age=604800; Secure; HttpOnly; SameSite=None", for: MapleHTTP.baseURL)
            return StubReply(Wire.changePasswordReplaced)
        }
        let h = try WireHarness(token: "old-session", routes: ["POST /api/auth/change-password": replacement])
        var changes = 0; h.auth.didChange = { changes += 1 }
        try await h.auth.changePassword(current: "OldPass123", new: "NewPass123", revokeOtherSessions: true)
        #expect(h.http.sessionToken == "new-session"); #expect(changes == 1)
        #expect(h.requests(to: "/api/auth/change-password").first?.json["revokeOtherSessions"] as? Bool == true)
    }

    @Test func sessionsAccountsAndRevocationDecodeTheRealReplies() async throws {
        var routes = signedInRoutes
        routes["GET /api/auth/list-sessions"] = StubReply(Wire.listSessions)
        routes["GET /api/auth/list-accounts"] = StubReply(Wire.listAccounts)
        routes["POST /api/auth/revoke-session"] = StubReply(Wire.status)
        routes["POST /api/auth/revoke-other-sessions"] = StubReply(Wire.status)
        routes["POST /api/auth/sign-out"] = StubReply(Wire.signOut)
        let h = try WireHarness(token: "test-session", routes)
        let sessions = try await h.auth.listSessions()
        #expect(sessions.map(\.id) == ["session-1", "session-2"]); #expect(sessions[1].ipAddress == "")
        #expect(try await h.auth.listAccounts().map(\.providerId) == ["credential"])
        let current = try #require(await h.auth.currentSession())
        #expect(current.session.id == "session-1"); #expect(current.user.email == "unit@example.test"); #expect(current.user.emailVerified)
        try await h.auth.revokeSession(token: "other-token")
        #expect(h.requests(to: "/api/auth/revoke-session").first?.json["token"] as? String == "other-token")
        try await h.auth.revokeOtherSessions()
        let revokeOthers = try #require(h.requests(to: "/api/auth/revoke-other-sessions").first)
        #expect(revokeOthers.method == "POST"); #expect(revokeOthers.origin == MapleHTTP.origin); #expect(revokeOthers.body == "{}")
        try await h.auth.signOut()
        let signOut = try #require(h.requests(to: "/api/auth/sign-out").first)
        #expect(signOut.origin == MapleHTTP.origin); #expect(signOut.cookie?.contains("test-session") == true)
        #expect(h.auth.user == nil); #expect(h.http.sessionToken == nil)
    }

    @Test func signOutEverywhereUsesTheRealRouteName() async throws {
        let h = try WireHarness(token: "test-session", ["POST /api/auth/revoke-sessions": StubReply(Wire.status)])
        try await h.auth.signOutEverywhere()
        let request = try #require(h.requests(to: "/api/auth/revoke-sessions").first)
        #expect(request.origin == MapleHTTP.origin); #expect(request.cookie?.contains("test-session") == true)
    }

    // MARK: Documented errors

    private struct ErrorCase {
        let route: String; let status: Int; let code: String?; let body: String
        let signedIn: Bool
        let run: @MainActor (AuthSessionModel) async throws -> Void
        init(_ route: String, _ status: Int, _ code: String?, message: String = "x", body: String? = nil, signedIn: Bool = false,
             run: @escaping @MainActor (AuthSessionModel) async throws -> Void) {
            self.route = route; self.status = status; self.code = code; self.signedIn = signedIn; self.run = run
            self.body = body ?? (code.map { #"{"code":"\#($0)","message":"\#(message)"}"# } ?? #"{"message":"\#(message)"}"#)
        }
    }

    /// Error bodies are `{code, message}` (Better Auth, `APIError.from`) with the statuses and codes below.
    @Test func everyDocumentedErrorKeepsItsStatusAndCode() async throws {
        let signIn: @MainActor (AuthSessionModel) async throws -> Void = { try await $0.signIn(identifier: "unit", password: "Secret123") }
        let emailSignIn: @MainActor (AuthSessionModel) async throws -> Void = { try await $0.signIn(identifier: "unit@example.test", password: "Secret123") }
        let signUp: @MainActor (AuthSessionModel) async throws -> Void = { try await $0.signUp(username: "newuser", email: "new@example.test", password: "Secret123") }
        let enroll: @MainActor (AuthSessionModel) async throws -> Void = { try await $0.enrollLegacy(username: "old", password: "Secret123", email: "legacy@example.test", newUsername: nil) }
        let changePassword: @MainActor (AuthSessionModel) async throws -> Void = { try await $0.changePassword(current: "a", new: "NewPass123", revokeOtherSessions: true) }
        let cases: [ErrorCase] = [
            // plugins/username/index.mjs + error-codes.mjs, api/auth/auth.ts
            ErrorCase("/api/auth/sign-in/username", 401, "INVALID_USERNAME_OR_PASSWORD", run: signIn),
            ErrorCase("/api/auth/sign-in/username", 403, "EMAIL_NOT_VERIFIED", run: signIn),
            ErrorCase("/api/auth/sign-in/username", 403, "LEGACY_ENROLLMENT_REQUIRED", run: signIn),
            ErrorCase("/api/auth/sign-in/username", 422, "USERNAME_TOO_SHORT", run: signIn),
            ErrorCase("/api/auth/sign-in/username", 429, nil, message: "Too many requests. Please try again later.", run: signIn),
            // api/routes/sign-in.mjs
            ErrorCase("/api/auth/sign-in/email", 401, "INVALID_EMAIL_OR_PASSWORD", run: emailSignIn),
            ErrorCase("/api/auth/sign-in/email", 403, "EMAIL_NOT_VERIFIED", run: emailSignIn),
            // api/auth/auth.ts before-hook and api/routes/sign-up.mjs
            ErrorCase("/api/auth/sign-up/email", 400, "USERNAME_IS_ALREADY_TAKEN", run: signUp),
            ErrorCase("/api/auth/sign-up/email", 400, "PASSWORD_POLICY", run: signUp),
            ErrorCase("/api/auth/sign-up/email", 400, "INVALID_USERNAME", run: signUp),
            ErrorCase("/api/auth/sign-up/email", 422, "FAILED_TO_CREATE_USER", run: signUp),
            // api/auth/legacy.ts
            ErrorCase("/api/auth/legacy/enroll", 401, "INVALID_LEGACY_CREDENTIALS", run: enroll),
            ErrorCase("/api/auth/legacy/enroll", 409, "ALREADY_ENROLLED", run: enroll),
            ErrorCase("/api/auth/legacy/enroll", 409, "EMAIL_UNAVAILABLE", run: enroll),
            ErrorCase("/api/auth/legacy/enroll", 400, "USERNAME_REPLACEMENT_REQUIRED", run: enroll),
            ErrorCase("/api/auth/legacy/enroll", 400, "INVALID_USERNAME", run: enroll),
            ErrorCase("/api/auth/legacy/enroll", 409, "USERNAME_TAKEN", run: enroll),
            ErrorCase("/api/auth/legacy/enroll", 409, "ENROLLMENT_CHANGED", run: enroll),
            ErrorCase("/api/auth/legacy/enroll", 500, "ENROLLMENT_FAILED", run: enroll),
            ErrorCase("/api/auth/legacy/enroll", 503, "EMAIL_DELIVERY_FAILED", run: enroll),
            ErrorCase("/api/auth/legacy/enroll", 400, "INVALID_EMAIL", run: enroll),
            // api/routes/email-verification.mjs, password.mjs
            ErrorCase("/api/auth/send-verification-email", 400, "EMAIL_ALREADY_VERIFIED", signedIn: true) { try await $0.resendVerification(email: "unit@example.test") },
            ErrorCase("/api/auth/request-password-reset", 429, nil) { try await $0.requestPasswordReset(email: "unit@example.test") },
            // api/routes/update-user.mjs: "Email is the same" has no code; sensitiveSessionMiddleware answers 401 UNAUTHORIZED
            ErrorCase("/api/auth/change-email", 400, nil, message: "Email is the same", signedIn: true) { try await $0.changeEmail("unit@example.test") },
            ErrorCase("/api/auth/change-email", 401, "UNAUTHORIZED", message: "Unauthorized", signedIn: true) { try await $0.changeEmail("next@example.test") },
            ErrorCase("/api/auth/change-password", 400, "INVALID_PASSWORD", signedIn: true, run: changePassword),
            ErrorCase("/api/auth/change-password", 400, "PASSWORD_POLICY", signedIn: true, run: changePassword),
            ErrorCase("/api/auth/change-password", 400, "PASSWORD_TOO_SHORT", signedIn: true, run: changePassword),
            ErrorCase("/api/auth/change-password", 400, "CREDENTIAL_ACCOUNT_NOT_FOUND", signedIn: true, run: changePassword),
            // api/routes/session.mjs: list-sessions needs a session younger than a day (freshAge default 86400)
            ErrorCase("/api/auth/list-sessions", 403, "SESSION_NOT_FRESH", message: "Session is not fresh", signedIn: true) { _ = try await $0.listSessions() },
            ErrorCase("/api/auth/revoke-session", 401, "UNAUTHORIZED", message: "Unauthorized", signedIn: true) { try await $0.revokeSession(token: "t") },
            ErrorCase("/api/auth/revoke-other-sessions", 401, "UNAUTHORIZED", message: "Unauthorized", signedIn: true) { try await $0.revokeOtherSessions() },
            ErrorCase("/api/auth/revoke-sessions", 500, "INTERNAL_SERVER_ERROR", message: "Internal Server Error", signedIn: true) { try await $0.signOutEverywhere() },
            ErrorCase("/api/auth/list-accounts", 401, "UNAUTHORIZED", message: "Unauthorized", signedIn: true) { _ = try await $0.listAccounts() },
        ]
        for item in cases {
            let method = item.route.contains("list-") ? "GET" : "POST"
            let h = try WireHarness(token: item.signedIn ? "test-session" : nil, ["\(method) \(item.route)": StubReply(item.body, status: item.status)])
            do {
                try await item.run(h.auth)
                Issue.record("\(item.route) \(item.status) \(item.code ?? "-") unexpectedly succeeded")
            } catch {
                let failure = MapleError.normalize(error) as? MapleError
                #expect(failure?.status == item.status, "\(item.route) status")
                #expect(failure?.code == item.code, "\(item.route) code")
                #expect(AccountErrorCopy.message(for: error) != nil, "\(item.route) has user-facing copy")
            }
        }
    }

    @Test func notFreshSessionExplainsItselfInsteadOfShowingRawServerText() {
        let error = MapleError(status: 403, code: "SESSION_NOT_FRESH", message: "Session is not fresh")
        #expect(AccountErrorCopy.message(for: error) == "For your security, sign out and sign in again before viewing your devices.")
        #expect(!AccountErrorCopy.endsSession(error))
    }

    // MARK: Maple's own routes

    @Test func mapleRoutesDecodeTheRealReplies() async throws {
        let h = try WireHarness(token: "test-session", [
            "GET /get/me": StubReply(Wire.me),
            "GET /user/friends/me": StubReply(Wire.friends),
            "GET /user/friends/me/requests": StubReply(Wire.requests),
            "GET /public/get/user/ada": StubReply(#"{"id":"f1","username":"ada","name":"Ada"}"#),
            "GET /public/get/user/id/f2": StubReply(#"{"id":"f2","username":"bob","name":null,"listening":null}"#),
            "PATCH /user/manage/me": StubReply(Wire.message),
            "PATCH /user/manage/me/listening": StubReply(Wire.message),
            "POST /user/friends/me/requests/f1": StubReply(Wire.message),
            "POST /user/friends/me/requests/f1/accept": StubReply(Wire.message),
            "DELETE /user/friends/me/requests/f1": StubReply(Wire.message),
            "DELETE /user/friends/me/f1": StubReply(Wire.message),
            "DELETE /user/manage/me": StubReply(Wire.message),
        ])
        let api = MapleAPI(http: h.http)
        let me = try await api.me()
        #expect(me.username == "unit"); #expect(me.pfp == Data([1, 2, 3])); #expect(me.listeningVisibility == .public)
        #expect(me.listening.lastPlayed?.title == "Song"); #expect(me.listening.lastPlayed?.playedAt != nil)
        let friends = try await api.friends()
        #expect(friends.map(\.id) == ["f1", "f2"]); #expect(friends[0].listening?.current?.playing == true)
        #expect(friends[0].listening?.current?.duration == nil); #expect(friends[1].listening == nil)
        #expect(try await api.requests().incoming.map(\.username) == ["cy"])
        #expect(try await api.profile(username: "ada").label == "Ada")
        #expect(try await api.profile(id: "f2").listening == nil)
        try await api.setDisplayName("Ada"); try await api.setListeningVisibility(.private)
        try await api.sendRequest(id: "f1"); try await api.acceptRequest(id: "f1")
        try await api.declineOrCancelRequest(id: "f1"); try await api.removeFriend(id: "f1")
        try await api.deleteAccount()
        #expect(h.requests(to: "/user/manage/me/listening").first?.json["visibility"] as? String == "private")
        #expect(h.sent.read().allSatisfy { $0.origin == MapleHTTP.origin })
    }

    /// api/publicGet/{get,image}.ts return image bytes; api/user/manageUser.ts's PUT replies are ignored.
    @Test func imageAndUploadRoutesConsumeTheirActualResponseKinds() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let data = try #require(image.pngData())
        var bytes = StubReply(); bytes.data = data; bytes.headers = ["Content-Type": "image/png"]
        let h = try WireHarness([
            "GET /public/get/pfp/u1": bytes,
            "GET /public/get/albumArt/u1/a1": bytes,
            "PUT /user/manage/me/pfp": StubReply(#"{"message":"Profile picture updated successfully"}"#),
            "PUT /user/manage/me/albumArt": StubReply(#"{"message":"Album art updated successfully"}"#),
        ])
        let api = MapleAPI(http: h.http)
        #expect(try await api.avatar(id: "u1") == data)
        #expect(try await api.artwork(id: "u1", artwork: "a1") == data)
        try await api.setAvatar(data)
        try await api.setAlbumArt(data, playbackId: "playing-1")
        #expect(h.sent.read().allSatisfy { $0.origin == MapleHTTP.origin })
    }

    @Test(arguments: [
        #""2020-01-01""#, #""2020-01-01 00:00:00""#, #""2026-11-16T09:00:00Z""#, #""2026-11-16T09:00:00.123Z""#,
        "null", #""not a date""#, #""""#,
    ])
    func legacyOrUnreadableLastPlayedTimeNeverBreaksTheProfile(playedAt: String) async throws {
        let h = try WireHarness(token: "test-session", ["GET /get/me": StubReply(Wire.meWithLegacyTime(playedAt))])
        let me = try await MapleAPI(http: h.http).me()
        let last = try #require(me.listening.lastPlayed)
        #expect(last.title == "Old")
        switch playedAt {
        case "null", #""not a date""#, #""""#: #expect(last.playedAt == nil)
        case #""2020-01-01""#:
            #expect(last.playedAt == Date(timeIntervalSince1970: 1_577_836_800))
        case #""2020-01-01 00:00:00""#:
            #expect(last.playedAt == Date(timeIntervalSince1970: 1_577_836_800))
        default: #expect(last.playedAt != nil)
        }
    }

    @Test func aFriendWithLegacyLastPlayedStillAppearsInTheList() async throws {
        let body = #"[{"id":"f1","username":"ada","name":null,"listening":{"current":null,"lastPlayed":{"title":"Old","artist":"Band","album":"LP","duration":null,"playedAt":"2020-01-01","artwork":null}}}]"#
        let h = try WireHarness(token: "test-session", ["GET /user/friends/me": StubReply(body)])
        #expect(try await MapleAPI(http: h.http).friends().first?.listening?.lastPlayed?.playedAt != nil)
    }

    @Test func mapleRouterErrorsKeepTheirTextAndPlainUnauthorizedIsHandled() async throws {
        let h = try WireHarness(token: "test-session", [
            "POST /user/friends/me/requests/f1": StubReply(#"{"error":"This user already sent you a friend request."}"#, status: 409),
            "GET /get/me": StubReply("Unauthorized", status: 401, headers: ["Content-Type": "text/plain; charset=utf-8"]),
        ])
        let api = MapleAPI(http: h.http)
        await #expect(throws: MapleError.self) { try await api.sendRequest(id: "f1") }
        do { try await api.sendRequest(id: "f1") } catch {
            #expect((error as? MapleError)?.error == "This user already sent you a friend request.")
            #expect(AccountErrorCopy.message(for: error) == "This person already sent you a request. Accept it in Friend Requests.")
        }
        await #expect(throws: MapleError.self) { _ = try await api.me() }
        #expect(h.http.sessionToken == nil, "a plain 401 on a session route ends the session")
    }

    // MARK: Passkeys (switched off, but decoded through the same client)

    @Test func passkeyManagementDecodesTheRealReplies() async throws {
        let h = try WireHarness(token: "test-session", [
            "GET /api/auth/passkey/list-user-passkeys": StubReply(Wire.passkeyList),
            "POST /api/auth/passkey/update-passkey": StubReply(Wire.passkeyUpdate),
            "POST /api/auth/passkey/delete-passkey": StubReply(Wire.passkeyDelete),
        ])
        let list = try await h.auth.listPasskeys()
        #expect(list.map(\.id) == ["pk-1"]); #expect(list.first?.name == nil); #expect(list.first?.createdAt != nil)
        #expect(list.first?.deviceType == .multiDevice)
        try await h.auth.renamePasskey(id: "pk-1", name: "iPhone")
        try await h.auth.deletePasskey(id: "pk-1")
        #expect(h.requests(to: "/api/auth/passkey/update-passkey").first?.json["name"] as? String == "iPhone")
        #expect(h.sent.read().allSatisfy { $0.origin == MapleHTTP.origin })
    }

    @Test func passkeyOptionsAndVerificationDecodeTheRealReplies() async throws {
        let h = try WireHarness(token: "test-session", [
            "GET /api/auth/passkey/generate-register-options": StubReply(Wire.registerOptions),
            "POST /api/auth/passkey/generate-authenticate-options": StubReply(Wire.authenticateOptions),
            "POST /api/auth/passkey/verify-registration": StubReply(Wire.passkeyRow),
            "POST /api/auth/passkey/verify-authentication": StubReply(Wire.passkeyAuthentication),
        ])
        let registration = try await h.auth.client.passkey.generateRegisterOptions(with: .init(name: "iPhone", authenticatorAttachment: .platform)).data
        #expect(registration.rp.id == "maple.music"); #expect(registration.user.displayName == "unit@example.test")
        #expect(registration.excludeCredentials?.first?.id == "Y3JlZC0x"); #expect(registration.pubKeyCredParams.map(\.alg) == [-8, -7, -257])
        let query = try #require(h.requests(to: "/api/auth/passkey/generate-register-options").first)
        #expect(query.method == "GET")

        let authentication = try await h.auth.client.passkey.generateAuthenticateOptions().data
        #expect(authentication.rpId == "maple.music"); #expect(authentication.allowCredentials?.first?.transports == [.internal, .hybrid])

        let assertion = PasskeyAuthenticationResponse(id: "Y3JlZC0x", rawId: "Y3JlZC0x",
            response: .init(clientDataJSON: "e30", authenticatorData: "AA", signature: "AA", userHandle: nil), clientExtensionResults: .init(), type: .publicKey)
        let verified = try await h.auth.client.passkey.verifyAuthentication(with: .init(response: assertion)).data
        #expect(verified.session.userId == Wire.id)

        let attestation = PasskeyRegistrationResponse(id: "Y3JlZC0x", rawId: "Y3JlZC0x",
            response: .init(clientDataJSON: "e30", attestationObject: "AA"), clientExtensionResults: .init(), type: .publicKey)
        let registered = try await h.auth.client.passkey.verifyRegistration(with: .init(response: attestation, name: "iPhone")).data
        #expect(registered.credentialID == "cred-1")
    }

    /// @better-auth/passkey 1.7.13 index.mjs uses transports?.split(","); simplewebauthn omits undefined fields.
    @Test func passkeyDescriptorsMayOmitTransportsAndResidentKeyUsesTheServerSpelling() async throws {
        let register = Wire.registerOptions.replacingOccurrences(of: #""transports":[""],"#, with: "")
        let authenticate = Wire.authenticateOptions.replacingOccurrences(of: #""transports":["internal","hybrid"],"#, with: "")
        let h = try WireHarness([
            "GET /api/auth/passkey/generate-register-options": StubReply(register),
            "POST /api/auth/passkey/generate-authenticate-options": StubReply(authenticate),
        ])
        let registration = try await h.auth.client.passkey.generateRegisterOptions(with: .init()).data
        #expect(registration.excludeCredentials?.first?.transports.isEmpty == true)
        #expect(registration.authenticatorSelection?.requiresResidentKey == false)
        let authentication = try await h.auth.client.passkey.generateAuthenticateOptions().data
        #expect(authentication.allowCredentials?.first?.transports.isEmpty == true)
    }

    @Test func discoverableAuthenticationOptionsHaveNoAllowList() async throws {
        let h = try WireHarness(token: nil, ["POST /api/auth/passkey/generate-authenticate-options": StubReply(Wire.authenticateOptionsDiscoverable)])
        let options = try await h.auth.client.passkey.generateAuthenticateOptions().data
        #expect(options.allowCredentials == nil); #expect(options.rpId == "maple.music")
    }

    // MARK: A password change must not end the session it replaces

    @Test func refreshIsDeferredWhileAPasswordChangeIsInFlight() async throws {
        let sent = TestGate(); let release = TestGate()
        var routes: [String: WireHarness.Route] = [:]
        routes["POST /api/auth/change-password"] = { jar in
            await sent.open(); await release.wait()
            try? jar.setCookie("__Secure-maple.session_token=new-session; Path=/; Secure", for: MapleHTTP.baseURL)
            return StubReply(Wire.changePasswordReplaced)
        }
        routes["GET /api/auth/get-session"] = { _ in StubReply("null") }
        let h = try WireHarness(token: "old-session", routes: routes)
        let change = Task { try await h.auth.changePassword(current: "OldPass123", new: "NewPass123", revokeOtherSessions: true) }
        await sent.wait()
        // The server just deleted the old session: asking it about the old cookie would answer `null`.
        await #expect(throws: MapleError.self) { try await h.auth.refresh() }
        #expect(h.requests(to: "/api/auth/get-session").isEmpty)
        await release.open(); try await change.value
        #expect(h.http.sessionToken == "new-session")
    }

    @Test func aNullAnswerForAReplacedCookieDoesNotSignOutTheNewSession() async throws {
        let sent = TestGate(); let release = TestGate(); let calls = Locked(0)
        var routes: [String: WireHarness.Route] = ["GET /get/me": { _ in StubReply(Wire.me) }]
        routes["GET /api/auth/get-session"] = { _ in
            if calls.update({ $0 += 1; return $0 }) == 1 { return StubReply(Wire.getSession) }
            await sent.open(); await release.wait()
            return StubReply("null")
        }
        let h = try WireHarness(token: "old-session", routes: routes)
        await h.auth.restore()
        #expect(h.auth.user != nil)
        let check = Task { try await h.auth.refresh() }
        await sent.wait()
        try h.jar.setCookie("__Secure-maple.session_token=new-session; Path=/; Secure", for: MapleHTTP.baseURL)
        await release.open(); try await check.value
        #expect(h.auth.user != nil); #expect(h.http.sessionToken == "new-session")
        await h.auth.invalidate()
    }

    /// A refresh sent before change-password can complete while deleteUserSessions is running.
    @Test(arguments: [200, 401], [true, false])
    func anOldRefreshCannotInvalidateAnInFlightPasswordReplacement(status: Int, replacementFirst: Bool) async throws {
        let refreshSent = TestGate(); let refreshRelease = TestGate()
        let changeSent = TestGate(); let changeRelease = TestGate(); let calls = Locked(0)
        let h = try WireHarness(token: "old-session", routes: [
            "GET /api/auth/get-session": { _ in
                if calls.update({ $0 += 1; return $0 }) == 1 { return StubReply(Wire.getSession) }
                await refreshSent.open(); await refreshRelease.wait()
                return StubReply(status == 200 ? "null" : #"{"code":"UNAUTHORIZED","message":"Unauthorized"}"#, status: status, headers: ["Set-Cookie": "__Secure-maple.session_token=; Path=/; Secure; Max-Age=0"])
            },
            "GET /get/me": { _ in StubReply(Wire.me) },
            "POST /api/auth/change-password": { jar in
                await changeSent.open(); await changeRelease.wait()
                return StubReply(Wire.changePasswordReplaced, headers: ["Set-Cookie": "__Secure-maple.session_token=new-session; Path=/; Secure; Max-Age=604800"])
            },
        ])
        await h.auth.restore()
        let refresh = Task { try? await h.auth.refresh() }
        await refreshSent.wait()
        let change = Task { try await h.auth.changePassword(current: "OldPass123", new: "NewPass123") }
        await changeSent.wait()
        if replacementFirst {
            await changeRelease.open(); try await change.value
            await refreshRelease.open(); await refresh.value
        } else {
            await refreshRelease.open(); await refresh.value
            #expect(h.auth.user != nil); #expect(h.http.sessionToken == "old-session")
            await changeRelease.open(); try await change.value
        }
        #expect(h.auth.user != nil); #expect(h.http.sessionToken == "new-session")
        await h.auth.invalidate()
    }

    @Test func failedPasswordChangeDoesNotBlockLaterSessionValidation() async throws {
        let h = try WireHarness(token: "test-session", [
            "POST /api/auth/change-password": StubReply(#"{"code":"INVALID_PASSWORD","message":"Invalid password"}"#, status: 400),
            "GET /api/auth/get-session": StubReply(Wire.getSession), "GET /get/me": StubReply(Wire.me),
        ])
        await #expect(throws: MapleError.self) { try await h.auth.changePassword(current: "wrong", new: "NewPass123") }
        try await h.auth.refresh()
        #expect(h.auth.user != nil)
        await h.auth.invalidate()
    }

    @Test func aNullAnswerForTheCurrentCookieStillSignsOut() async throws {
        let h = try WireHarness(token: "test-session", ["GET /api/auth/get-session": StubReply("null")])
        try await h.auth.refresh()
        #expect(h.auth.user == nil); #expect(h.http.sessionToken == nil)
    }
}
