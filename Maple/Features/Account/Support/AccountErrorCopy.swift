import Foundation

/// Turns any error from the account and friends flows into short, plain-language copy.
/// Never returns raw response bodies, tokens or identifiers. `nil` means "nothing to show" (cancellation).
enum AccountErrorCopy {
    static let generic = "Something went wrong. Try again."

    static func message(for error: Error) -> String? {
        if error is CancellationError { return nil }
        if let error = error as? URLError { return network(error) }
        if error is DecodingError { return "Maple sent an unexpected response. Try again." }
        guard let error = MapleError.normalize(error) as? MapleError else { return generic }
        if let code = error.code, let text = codes[code] { return text }
        if let text = error.error ?? error.message, let mapped = routerErrors[text] { return mapped }
        switch error.status {
        case 429: return "Too many attempts. Wait a minute and try again."
        case 413: return "Choose an image smaller than 3 MB."
        case 401: return "Your session has ended. Sign in again."
        case 500...599: return "Maple is unavailable right now. Try again shortly."
        default: break
        }
        // Server-written copy (Better Auth `message`, Maple `error`) is already human; keep it if it looks like a sentence.
        if let text = error.message ?? error.error, isHumanReadable(text) { return text }
        return generic
    }

    /// Code of a Better Auth / Maple error, if any.
    static func code(of error: Error) -> String? { (MapleError.normalize(error) as? MapleError)?.code }
    static func status(of error: Error) -> Int? { (MapleError.normalize(error) as? MapleError)?.status }

    /// In a signed-in context, any 401 means the session is gone.
    static func endsSession(_ error: Error) -> Bool { status(of: error) == 401 }

    static func isOffline(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return offlineCodes.contains(error.code)
    }

    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
        .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed
    ]
    private static func network(_ error: URLError) -> String? {
        if error.code == .cancelled { return nil }
        if offlineCodes.contains(error.code) { return "You’re offline. Check your connection and try again." }
        if error.code == .timedOut { return "Maple took too long to respond. Try again." }
        if error.code == .secureConnectionFailed || error.code == .serverCertificateUntrusted {
            return "A secure connection to Maple couldn’t be made."
        }
        return "Maple couldn’t be reached. Try again."
    }
    private static func isHumanReadable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 200 && trimmed != "Unauthorized"
            && !trimmed.hasPrefix("{") && !trimmed.hasPrefix("<") && trimmed.first?.isLetter == true
    }

    /// Better Auth, username/passkey plugin and legacy-enrollment codes.
    static let codes: [String: String] = [
        // Sign-in
        "INVALID_USERNAME_OR_PASSWORD": "The username or password is incorrect.",
        "INVALID_EMAIL_OR_PASSWORD": "The email or password is incorrect.",
        "EMAIL_NOT_VERIFIED": "Verify your email address to continue.",
        "LEGACY_ENROLLMENT_REQUIRED": "Add an email address to finish moving your account.",
        "SESSION_EXPIRED": "For your security, sign out and sign in again before doing this.",
        // Registration and validation
        "USERNAME_IS_ALREADY_TAKEN": "That username is already taken.",
        "USERNAME_TAKEN": "That username is already taken.",
        "USER_ALREADY_EXISTS": "An account already uses that email. Sign in, or use a different email.",
        "USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL": "An account already uses that email. Sign in, or use a different email.",
        "INVALID_EMAIL": "Enter a valid email address.",
        "PASSWORD_TOO_SHORT": "Password must be at least 8 characters.",
        "PASSWORD_TOO_LONG": "Password must be at most 128 characters.",
        "USERNAME_TOO_SHORT": "Username must be at least 2 characters.",
        "USERNAME_TOO_LONG": "Username must be at most 32 characters.",
        // Legacy enrollment
        "INVALID_LEGACY_CREDENTIALS": "The username or password is incorrect.",
        "ALREADY_ENROLLED": "This account has already been moved. Sign in instead.",
        "EMAIL_UNAVAILABLE": "That email is used by another account. Use a different email address.",
        "USERNAME_REPLACEMENT_REQUIRED": "Your old username is no longer allowed. Choose a new one.",
        "ENROLLMENT_CHANGED": "This account changed while it was being moved. Try again.",
        "ENROLLMENT_FAILED": "Your account couldn’t be moved. Try again.",
        "EMAIL_DELIVERY_FAILED": "The verification email couldn’t be sent. Try again shortly.",
        // Security
        "INVALID_PASSWORD": "Your current password is incorrect.",
        "CREDENTIAL_ACCOUNT_NOT_FOUND": "This account doesn’t have a password yet.",
        "EMAIL_CAN_NOT_BE_UPDATED": "Your email can’t be changed right now.",
        // Passkeys
        "PASSKEY_NOT_FOUND": "That passkey no longer exists.",
        "AUTHENTICATION_FAILED": "The passkey wasn’t accepted. Try again or use your password.",
        "FAILED_TO_VERIFY_REGISTRATION": "The passkey was not added.",
        "CHALLENGE_NOT_FOUND": "The passkey request expired. Try again.",
        "YOU_ARE_NOT_ALLOWED_TO_REGISTER_THIS_PASSKEY": "This passkey can’t be added to your account.",
    ]

    /// Maple router `{error}` strings from the contract, reworded for iOS.
    static let routerErrors: [String: String] = [
        "User not found": "No one on Maple uses that username.",
        "You cannot friend your own account.": "You can’t add yourself as a friend.",
        "You are already friends.": "You’re already friends.",
        "Friend request already sent.": "You’ve already sent this person a request.",
        "This user already sent you a friend request.": "This person already sent you a request. Accept it in Friend Requests.",
        "Friend request not found": "That request is no longer available.",
        "You are not friends.": "You’re not friends with this person anymore.",
        "Upload a JPG, PNG or GIF image.": "Choose a JPEG, PNG or GIF image.",
        "File size exceeds 3MB limit.": "Choose an image smaller than 3 MB.",
        "Choose a valid image.": "That file isn’t an image Maple can use. Choose a different photo.",
    ]
}
