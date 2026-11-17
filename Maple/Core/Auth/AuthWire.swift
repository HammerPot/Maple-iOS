import Foundation

/// Request and reply models for the Better Auth routes Maple calls through `MapleHTTP`.
///
/// BetterAuthSwift's own response types require fields the Maple server leaves out or sends as `null`
/// (sign-up `token`, change-email `message`), and a decode failure after a 2xx reply reports an
/// operation that already happened as a failure. These types follow what the server really sends
/// (Better Auth 1.7.13 as configured by upstream `api/auth/auth.ts`); each one names the route
/// source it was derived from. Nullable fields stay optional; required fields still validate the reply.
/// The library client is still used for the passkey routes.

/// `POST /sign-up/email` (better-auth `api/routes/sign-up.ts`). Maple requires email verification, so the
/// server creates no session: `{"token": null, "user": {…}}` with no `Set-Cookie`.
struct SignUpReply: Decodable, Sendable {
    let token: String?
    let user: AuthUser
}

/// `POST /sign-in/email` and `POST /sign-in/username` (`api/routes/sign-in.ts`, `plugins/username`):
/// `{redirect, token, url, user}`. `url`/`redirect` echo the callback URL Maple's server fills in.
struct SignInReply: Decodable, Sendable {
    let token: String
    let user: AuthUser
    let redirect: Bool
    let url: String?
}

/// `POST /change-password` (`api/routes/update-user.ts`): `token` is `null` unless other sessions were
/// revoked, in which case the server also replaces the session cookie.
struct ChangePasswordReply: Decodable, Sendable {
    let token: String?
    let user: AuthUser
}

/// Request bodies. `nil` fields are omitted, so the server's defaults (callback URLs) apply.
enum AuthRequest {
    struct SignUp: Encodable, Sendable {
        let email: String, password: String, name: String, username: String
    }
    struct SignInEmail: Encodable, Sendable { let email: String, password: String }
    struct SignInUsername: Encodable, Sendable { let username: String, password: String }
    struct SendVerification: Encodable, Sendable { let email: String, callbackURL: String }
    struct PasswordReset: Encodable, Sendable { let email: String, redirectTo: String }
    struct ChangeEmail: Encodable, Sendable { let newEmail: String, callbackURL: String }
    struct ChangePassword: Encodable, Sendable {
        let currentPassword: String, newPassword: String, revokeOtherSessions: Bool
    }
    struct RevokeSession: Encodable, Sendable { let token: String }
    struct LegacyEnrollment: Encodable, Sendable {
        let username: String, password: String, email: String, newUsername: String?
    }
    /// Better Auth routes without parameters still receive a JSON object, as the web client sends.
    struct Empty: Encodable, Sendable {}
}
