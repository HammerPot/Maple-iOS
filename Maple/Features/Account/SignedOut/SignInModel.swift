import Foundation
import Observation
import OSLog

@MainActor @Observable
final class SignInModel {
    var identifier = ""
    var password = ""
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    /// Set when the server's answer needs a different screen.
    var route: SignedOutRoute?

    @ObservationIgnored private let session: any SignInService
    @ObservationIgnored private let logger = Logger(subsystem: "dev.hammerpot.Maple-iOS", category: "Account")

    init(session: any SignInService) { self.session = session }

    var isEmail: Bool { AccountRules.isEmail(identifier.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var canSubmit: Bool {
        !isBusy && !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    func signIn() async {
        guard canSubmit else { return }
        // Like the web client, an email is trimmed; a username is sent as typed (legacy names may differ).
        let email = isEmail
        let name = email ? identifier.trimmingCharacters(in: .whitespacesAndNewlines) : identifier
        let secret = password
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            try await session.signIn(identifier: name, password: secret)
            password = ""
        } catch {
            switch AccountErrorCopy.code(of: error) {
            case "EMAIL_NOT_VERIFIED":
                // The server has just re-sent the verification email (sendOnSignIn).
                route = .verify(VerificationContext(email: email ? name : nil, username: email ? nil : name,
                                                    password: secret, origin: .signIn))
                password = ""
            case "LEGACY_ENROLLMENT_REQUIRED":
                route = .legacy(LegacyContext(username: name, password: secret, fromSignIn: true))
                password = ""
            default:
                logger.notice("Sign-in failed: \(AccountErrorCopy.code(of: error) ?? "status \(AccountErrorCopy.status(of: error) ?? 0)", privacy: .public)")
                errorMessage = AccountErrorCopy.message(for: error)
            }
        }
    }

    func signInWithPasskey() async {
        guard PasskeySupport.isEnabled, !isBusy else { return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do { try await session.signInWithPasskey() }
        catch { errorMessage = PasskeySupport.message(for: error, purpose: .signIn) }
    }

    func clearError() { errorMessage = nil }
}
