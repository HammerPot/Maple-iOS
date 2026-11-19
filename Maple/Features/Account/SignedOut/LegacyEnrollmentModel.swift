import Foundation
import Observation

/// Moves a pre-5.0 account: adds a verified email and, when the old username is no longer allowed, a new one.
@MainActor @Observable
final class LegacyEnrollmentModel {
    var username: String
    var password: String
    var email = "" { didSet { if email != oldValue { emailServerError = nil } } }
    var newUsername = "" { didSet { if newUsername != oldValue { newUsernameServerError = nil } } }
    let fromSignIn: Bool
    private(set) var needsNewUsername = false
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var alreadyEnrolled = false
    private(set) var verification: VerificationContext?
    private var emailServerError: String?
    private var newUsernameServerError: String?

    @ObservationIgnored private let session: any SignInService

    init(context: LegacyContext, session: any SignInService) {
        username = context.username; password = context.password; fromSignIn = context.fromSignIn
        self.session = session
    }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    var emailError: String? { emailServerError ?? (email.isEmpty ? nil : AccountRules.emailProblem(trimmedEmail)) }
    var newUsernameError: String? {
        newUsernameServerError ?? (newUsername.isEmpty ? nil : AccountRules.usernameProblem(newUsername))
    }
    var canSubmit: Bool {
        !isBusy && !password.isEmpty && !trimmedEmail.isEmpty && AccountRules.emailProblem(trimmedEmail) == nil
            && emailServerError == nil
            && (!needsNewUsername || (AccountRules.usernameProblem(newUsername) == nil && newUsernameServerError == nil))
    }

    func enroll() async {
        guard canSubmit else { return }
        // The original username is sent exactly as typed; it may legitimately be empty or unusual.
        let replacement = needsNewUsername ? newUsername : nil
        let address = trimmedEmail.lowercased()
        isBusy = true; errorMessage = nil; alreadyEnrolled = false
        defer { isBusy = false }
        do {
            try await session.enrollLegacy(username: username, password: password, email: address, newUsername: replacement)
            finish(address: address, replacement: replacement, notice: nil)
        } catch {
            let message = AccountErrorCopy.message(for: error)
            switch AccountErrorCopy.code(of: error) {
            case "EMAIL_DELIVERY_FAILED":
                // Enrolled; only the email failed. Continue to the pending screen, where Resend works.
                finish(address: address, replacement: replacement,
                       notice: "Your account was moved, but the verification email couldn’t be sent. Tap Resend Email in a moment.")
            case "USERNAME_REPLACEMENT_REQUIRED":
                needsNewUsername = true
                errorMessage = message
            case "INVALID_USERNAME", "USERNAME_TAKEN":
                newUsernameServerError = message
            case "INVALID_EMAIL", "EMAIL_UNAVAILABLE":
                emailServerError = message
            case "ALREADY_ENROLLED":
                alreadyEnrolled = true
                errorMessage = message
            default:
                errorMessage = message
            }
        }
    }

    private func finish(address: String, replacement: String?, notice: String?) {
        let renamed = replacement.map { "Your username is now \($0)." }
        let combined = [renamed, notice].compactMap { $0 }.joined(separator: " ")
        verification = VerificationContext(email: address, username: replacement ?? username, password: password,
                                           origin: .legacy, notice: combined.isEmpty ? nil : combined)
        password = ""
    }
}
