import Foundation
import AuthenticationServices

enum PasskeySupport {
    /// The one switch for every passkey surface: the sign-in button, Passkeys in Security, and the one-time
    /// "Add a passkey?" prompt.
    ///
    /// Upstream prerequisite: iOS only allows passkeys for the relying party `maple.music` when
    /// `https://maple.music/.well-known/apple-app-site-association` lists this app
    /// (`ZNZ64553FT.dev.hammerpot.Maple-iOS` under `webcredentials.apps`). As of 2026-11-16 that file returns
    /// 404, and the server's WebAuthn origins may also need the native origin. Flip to `true` once both ship.
    static let isEnabled = false

    enum Purpose { case signIn, register }

    /// Plain-language copy for an AuthenticationServices failure, or nil when the person cancelled.
    static func message(for error: Error, purpose: Purpose) -> String? {
        let nsError = error as NSError
        if nsError.domain == ASAuthorizationError.errorDomain {
            switch ASAuthorizationError.Code(rawValue: nsError.code) {
            case .canceled?: return nil
            case .failed? where isDomainAssociationFailure(nsError):
                return "Passkeys aren’t available for Maple on this device yet. Use your password instead."
            default:
                return purpose == .signIn ? "Passkey sign-in did not finish." : "The passkey was not added."
            }
        }
        return AccountErrorCopy.message(for: error)
    }

    /// iOS reports a missing or stale apple-app-site-association entry as a generic `.failed` error whose
    /// description says the app "is not associated with domain".
    static func isDomainAssociationFailure(_ error: NSError) -> Bool {
        let texts = [error.localizedDescription, error.localizedFailureReason ?? "",
                     (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription ?? ""]
        return texts.contains { $0.localizedCaseInsensitiveContains("not associated with domain") }
    }
}
