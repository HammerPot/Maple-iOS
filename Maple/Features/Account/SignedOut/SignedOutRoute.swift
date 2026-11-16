import Foundation

/// What the verification-pending screen knows. Credentials live only in memory for as long as the flow
/// is on screen, so "I’ve Verified" and "Change Email" can finish without retyping; they are never persisted.
struct VerificationContext: Hashable {
    enum Origin: Hashable { case signIn, register, legacy, session }
    var email: String?
    var username: String?
    var password: String?
    var origin: Origin
    /// Shown once at the top of the screen, e.g. "Your username is now …".
    var notice: String? = nil

    var canSignIn: Bool { (username ?? email) != nil && password?.isEmpty == false }
    /// `/legacy/enroll` is the only route that can change the address of an unverified account without a
    /// session. It needs the username and password, so it is offered only when both are known.
    var canChangeEmail: Bool { username?.isEmpty == false && password?.isEmpty == false }
}

struct LegacyContext: Hashable {
    var username = ""
    var password = ""
    /// True when sign-in already proved the credentials, so only the email is asked for.
    var fromSignIn = false
}

enum SignedOutRoute: Hashable {
    case register
    case forgotPassword(email: String)
    case legacy(LegacyContext)
    case verify(VerificationContext)
}
