#if DEBUG
import Foundation
import SwiftUI

/// Opt-in simulator checks. No credentials, fake sessions, or account mutations are seeded.
enum AccountVerificationSupport {
    static var showsChecks: Bool { ProcessInfo.processInfo.arguments.contains("--maple-account-checks") }
    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        if ProcessInfo.processInfo.arguments.contains("--maple-offline") {
            UserDefaults.standard.set(false, forKey: "mapleAccountCheckOnline")
            configuration.protocolClasses = [AccountOfflineProtocol.self]
        }
        return configuration
    }
}

/// Makes the API unreachable only for this debug app process; other simulators retain network access.
private final class AccountOfflineProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        !UserDefaults.standard.bool(forKey: "mapleAccountCheckOnline")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var failure: DispatchWorkItem?
    override func startLoading() {
        let failure = DispatchWorkItem { [weak self] in
            guard let self else { return }
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        self.failure = failure
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: failure)
    }
    override func stopLoading() { failure?.cancel() }
}

struct AccountVerificationChecks: View {
    var body: some View {
        List {
            if ProcessInfo.processInfo.arguments.contains("--maple-offline") {
                Button("Restore API Access") {
                    UserDefaults.standard.set(true, forKey: "mapleAccountCheckOnline")
                }
            }
            NavigationLink("Private Listening Example") {
                List {
                    FriendRow(friend: ListeningProfile(id: "preview", username: "maple-preview", name: "Maple Preview", listening: nil), receivedAt: .now)
                    ListeningCard(userID: "preview", status: .hidden, receivedAt: .now)
                }
                .navigationTitle("Private Listening")
            }
            NavigationLink("Public Listening Example") {
                List {
                    ListeningCard(userID: "preview", status: .lastPlayed(LastPlayed(
                        title: "Maple Friends Listening Check", artist: "Maple Preview",
                        album: "Account Integration", duration: 240, playedAt: .now, artwork: nil)), receivedAt: .now)
                }
                .navigationTitle("Public Listening")
            }
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
