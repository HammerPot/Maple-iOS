import Foundation
import Observation

@MainActor @Observable
final class RegisterModel {
    var email = "" { didSet { if email != oldValue { serverEmailError = nil } } }
    var username = "" { didSet { if username != oldValue { serverUsernameError = nil } } }
    var password = "" { didSet { if password != oldValue { serverPasswordError = nil } } }
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var verification: VerificationContext?
    private var serverEmailError: String?
    private var serverUsernameError: String?
    private var serverPasswordError: String?

    @ObservationIgnored private let session: any SignInService
    init(session: any SignInService) { self.session = session }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    // Like the web client, a field is only judged once something has been typed in it.
    var emailError: String? { serverEmailError ?? (email.isEmpty ? nil : AccountRules.emailProblem(trimmedEmail)) }
    var usernameError: String? { serverUsernameError ?? (username.isEmpty ? nil : AccountRules.usernameProblem(username)) }
    var passwordError: String? { serverPasswordError ?? (password.isEmpty ? nil : AccountRules.passwordProblem(password)) }

    var canSubmit: Bool {
        !isBusy && AccountRules.emailProblem(trimmedEmail) == nil && AccountRules.usernameProblem(username) == nil
            && AccountRules.passwordProblem(password) == nil
            && serverEmailError == nil && serverUsernameError == nil && serverPasswordError == nil
    }

    func register() async {
        guard canSubmit else { return }
        let address = trimmedEmail, name = username, secret = password
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            try await session.signUp(username: name, email: address, password: secret)
            verification = VerificationContext(email: address, username: name, password: secret, origin: .register)
            password = ""
        } catch {
            let message = AccountErrorCopy.message(for: error)
            switch AccountErrorCopy.code(of: error) {
            case "USERNAME_IS_ALREADY_TAKEN", "INVALID_USERNAME", "USERNAME_TOO_SHORT", "USERNAME_TOO_LONG":
                serverUsernameError = message
            case "PASSWORD_POLICY", "PASSWORD_TOO_SHORT", "PASSWORD_TOO_LONG":
                serverPasswordError = message
            case "INVALID_EMAIL", "USER_ALREADY_EXISTS", "USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL":
                serverEmailError = message
            default:
                errorMessage = message
            }
        }
    }
}
