import Foundation
import Observation
import OSLog

/// Verification finishes in the browser (Maple only trusts web callback URLs), so this screen:
/// - polls for a verified session without side effects, every `pollInterval` and when the app returns to the
///   foreground (this succeeds whenever a session cookie exists for the account);
/// - offers "I’ve Verified", which signs in once with the in-memory credentials. That is the dependable path:
///   an unverified sign-in returns no cookie, so a session poll alone cannot see a browser verification;
/// - resends the email with a cooldown, and changes the address only where the server supports it.
@MainActor @Observable
final class VerifyEmailModel {
    static let pollInterval: Duration = .seconds(5)
    static let resendCooldown: TimeInterval = 60

    private(set) var context: VerificationContext
    private(set) var isBusy = false
    private(set) var isVerified = false
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var resendAvailableAt: Date
    /// Set when the screen has no credentials to finish with, so it should return to sign-in.
    private(set) var needsSignIn = false
    var newEmail = ""
    private(set) var changeEmailError: String?

    @ObservationIgnored private let session: any SignInService
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private var isChecking = false
    @ObservationIgnored private let logger = Logger(subsystem: "dev.hammerpot.Maple-iOS", category: "Account")

    init(context: VerificationContext, session: any SignInService, clock: @escaping () -> Date = Date.init,
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.context = context; self.session = session; self.clock = clock; self.sleep = sleep
        statusMessage = context.notice
        // Sign-up, enrollment and an unverified sign-in have each just sent an email.
        resendAvailableAt = context.origin == .session ? clock() : clock().addingTimeInterval(Self.resendCooldown)
    }

    func secondsUntilResend(at now: Date) -> Int { max(0, Int((resendAvailableAt.timeIntervalSince(now)).rounded(.up))) }
    var canResend: Bool { !isBusy && secondsUntilResend(at: clock()) == 0 && (context.email != nil || context.canSignIn) }

    /// One side-effect-free check for a verified session.
    func check() async {
        guard !isVerified, !isChecking else { return }
        isChecking = true; defer { isChecking = false }
        do { if try await session.refreshIfVerified() { isVerified = true } }
        catch { logger.debug("Verification check failed; will retry") }
    }

    /// Runs until cancelled (the view disappears) or verification is seen.
    func poll() async {
        while !isVerified {
            do { try await sleep(Self.pollInterval) } catch { return }
            await check()
        }
    }

    /// "I’ve Verified": sign in once with the in-memory credentials.
    func continueAfterVerifying() async {
        guard !isBusy else { return }
        guard context.canSignIn, let identifier = context.username ?? context.email, let password = context.password else {
            needsSignIn = true; return
        }
        isBusy = true; errorMessage = nil; statusMessage = nil
        defer { isBusy = false }
        do {
            try await session.signIn(identifier: identifier, password: password)
            isVerified = true
        } catch where AccountErrorCopy.code(of: error) == "EMAIL_NOT_VERIFIED" {
            // The server re-sent the email as part of that attempt.
            statusMessage = "Your email isn’t verified yet. We sent another link — open it, then try again."
            startCooldown()
        } catch {
            errorMessage = AccountErrorCopy.message(for: error)
        }
    }

    func resend() async {
        guard canResend else { return }
        isBusy = true; errorMessage = nil; statusMessage = nil
        defer { isBusy = false }
        do {
            if let email = context.email {
                try await session.resendVerification(email: email)
            } else if let identifier = context.username, let password = context.password {
                // Without an address, an unverified sign-in is how the server resends (as the web client does).
                do { try await session.signIn(identifier: identifier, password: password); isVerified = true; return }
                catch where AccountErrorCopy.code(of: error) == "EMAIL_NOT_VERIFIED" { }
            }
            statusMessage = "We sent another link."
            startCooldown()
        } catch {
            errorMessage = AccountErrorCopy.message(for: error)
        }
    }

    var newEmailProblem: String? {
        let trimmed = newEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let problem = AccountRules.emailProblem(trimmed) { return problem }
        if trimmed.caseInsensitiveCompare(context.email ?? "") == .orderedSame { return "That’s the address we already sent to." }
        return nil
    }
    var canChangeEmail: Bool {
        context.canChangeEmail && !isBusy && !newEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && newEmailProblem == nil
    }

    /// Returns true when the address changed and a new link was sent (or the account changed but delivery failed).
    @discardableResult
    func changeEmail() async -> Bool {
        guard canChangeEmail, let username = context.username, let password = context.password else { return false }
        let address = newEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        isBusy = true; changeEmailError = nil; errorMessage = nil; statusMessage = nil
        defer { isBusy = false }
        do {
            try await session.enrollLegacy(username: username, password: password, email: address, newUsername: nil)
            context.email = address; newEmail = ""
            statusMessage = "We sent a new link to \(address)."
            startCooldown()
            return true
        } catch {
            switch AccountErrorCopy.code(of: error) {
            case "EMAIL_DELIVERY_FAILED":
                context.email = address; newEmail = ""
                errorMessage = "Your email was changed, but the link couldn’t be sent. Tap Resend Email in a moment."
                return true
            case "ALREADY_ENROLLED":
                // Verification finished meanwhile.
                isBusy = false
                await continueAfterVerifying()
                return false
            default:
                changeEmailError = AccountErrorCopy.message(for: error)
                return false
            }
        }
    }

    private func startCooldown() { resendAvailableAt = clock().addingTimeInterval(Self.resendCooldown) }
}
