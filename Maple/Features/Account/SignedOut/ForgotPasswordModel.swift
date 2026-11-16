import Foundation
import Observation

@MainActor @Observable
final class ForgotPasswordModel {
    var email: String
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    /// The address the reset link was requested for.
    private(set) var sentTo: String?

    @ObservationIgnored private let session: any SignInService
    init(email: String = "", session: any SignInService) { self.email = email; self.session = session }

    private var trimmed: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    var emailError: String? { email.isEmpty ? nil : AccountRules.emailProblem(trimmed) }
    var canSubmit: Bool { !isBusy && !trimmed.isEmpty && AccountRules.emailProblem(trimmed) == nil }

    func send() async {
        guard canSubmit else { return }
        let address = trimmed
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            try await session.requestPasswordReset(email: address)
            sentTo = address
        } catch {
            errorMessage = AccountErrorCopy.message(for: error)
        }
    }
    func startOver() { sentTo = nil; errorMessage = nil }
}
