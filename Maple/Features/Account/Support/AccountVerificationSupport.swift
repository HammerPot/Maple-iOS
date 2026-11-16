#if DEBUG
import Foundation
import SwiftUI

/// Opt-in simulator checks. No credentials, fake sessions, or account mutations are seeded.
enum AccountVerificationSupport {
    static var showsChecks: Bool { ProcessInfo.processInfo.arguments.contains("--maple-account-checks") }
    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        if ProcessInfo.processInfo.arguments.contains("--maple-offline") {
            configuration.protocolClasses = [AccountOfflineProtocol.self]
        }
        return configuration
    }
}

/// Makes the API unreachable only for this debug app process; other simulators retain network access.
private final class AccountOfflineProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

struct AccountVerificationChecks: View {
    var body: some View {
        List {
            NavigationLink("Verification Pending") {
                VerifyEmailView(context: VerificationContext(email: "preview@example.test", username: "preview",
                    password: "PreviewOnly", origin: .legacy), session: PreviewSignInService())
            }
        }
        .navigationTitle("Account Checks")
    }
}

/// Preview actions can never send an email or sign in on production.
@MainActor private final class PreviewSignInService: SignInService {
    func invalidate() async {}
    func refreshIfVerified() async throws -> Bool { false }
    func signIn(identifier: String, password: String) async throws { throw CancellationError() }
    func signUp(username: String, email: String, password: String) async throws { throw CancellationError() }
    func resendVerification(email: String) async throws { throw CancellationError() }
    func enrollLegacy(username: String, password: String, email: String, newUsername: String?) async throws { throw CancellationError() }
    func requestPasswordReset(email: String) async throws { throw CancellationError() }
    func signInWithPasskey() async throws { throw CancellationError() }
}
#endif
