import Foundation
import Testing
@testable import Maple

@MainActor
struct AccountIntegrationTests {
    @Test func lateVerificationCheckCannotRestoreSignedOutSession() async throws {
        let sent = TestGate(); let release = TestGate()
        let http = try testHTTP { request in
            await sent.open(); await release.wait()
            return signedInReply(request)
        }
        let auth = AuthSessionModel(api: MapleAPI(http: http))
        let checking = Task { try await auth.refreshIfVerified() }
        await sent.wait(); await auth.invalidate(); await release.open()
        #expect(try await checking.value == false)
        #expect(auth.user == nil && http.sessionToken == nil)
    }

    @Test func registrationCannotUseLegacyEnrollmentToChangeEmail() async {
        let service = FakeSignInService()
        let context = VerificationContext(email: "first@example.test", username: "newuser", password: "Secret123", origin: .register)
        let model = VerifyEmailModel(context: context, session: service)
        model.newEmail = "other@example.test"
        #expect(!context.canChangeEmail && !model.canChangeEmail)
        #expect(await model.changeEmail() == false)
        #expect(service.enrollments.isEmpty)
    }

    @Test func signOutEverywhereIsLocalFirstAndFencesLaterCookies() async throws {
        let sent = TestGate(); let release = TestGate()
        let captured = Locked<URLRequest?>(nil)
        let http = try testHTTP { request in
            if request.url?.path == "/api/auth/revoke-sessions" {
                captured.update { $0 = request }; await sent.open(); await release.wait()
                return StubReply(status: 503, headers: ["Set-Cookie": "__Secure-maple.session_token=; Max-Age=0; Path=/; Secure"])
            }
            return signedInReply(request)
        }
        let auth = AuthSessionModel(api: MapleAPI(http: http)); await auth.restore()
        let signingOut = Task { try await auth.signOutEverywhere() }
        await sent.wait()
        #expect(auth.user == nil && http.sessionToken == nil && !auth.isRestoring)
        #expect(captured.read()?.value(forHTTPHeaderField: "Cookie")?.contains("test-session") == true)
        try http.cookies.setCookie("__Secure-maple.session_token=later-session; Path=/; Secure", for: MapleHTTP.baseURL)
        await release.open()
        await #expect(throws: MapleError.self) { try await signingOut.value }
        #expect(http.sessionToken == "later-session")
        await auth.invalidate()
    }

    @Test(arguments: [401, 403]) func featureSessionReadsRespectRejectionStatus(_ status: Int) async throws {
        let http = try testHTTP { _ in StubReply(status: status) }
        let auth = AuthSessionModel(api: MapleAPI(http: http))
        _ = try? await auth.currentSession()
        #expect((http.sessionToken == nil) == (status == 401))
        _ = try? await auth.refreshIfVerified()
        #expect((http.sessionToken == nil) == (status == 401))
        await auth.invalidate()
    }

    @Test func retryKeepsUnreachableVisibleAndOfflineSignOutResolvesIt() async throws {
        let sent = TestGate(); let release = TestGate(); let sleeper = TestSleeper()
        let calls = Locked(0)
        let http = try testHTTP { _ in
            let count = calls.update { $0 += 1; return $0 }
            if count == 2 { await sent.open(); await release.wait() }
            throw URLError(.notConnectedToInternet)
        }
        let auth = AuthSessionModel(api: MapleAPI(http: http), sleep: { try await sleeper.sleep($0) })
        await auth.restore()
        let retry = Task { await auth.retryRestore() }; await sent.wait()
        #expect(auth.sessionUnreachable && auth.isRestoring && auth.user == nil)
        #expect(http.sessionToken != nil)
        await release.open(); await retry.value
        try await auth.signOut()
        #expect(!auth.sessionUnreachable && !auth.isRestoring && http.sessionToken == nil)
    }

    @Test func refreshOverlayKeepsEventTimestampAndDoesNotLeakIntoNextSnapshot() async throws {
        let started = TestGate(); let release = TestGate(); let calls = Locked(0)
        let http = try testHTTP { request in
            if request.url?.path.hasSuffix("requests") == true { return StubReply(#"{"incoming":[],"outgoing":[]}"#) }
            let count = calls.update { $0 += 1; return $0 }
            if count == 1 { await started.open(); await release.wait() }
            return StubReply(#"[{"id":"friend","username":"friend","name":null,"listening":{"current":null,"lastPlayed":null}}]"#)
        }
        let clock = TestClock()
        let friends = FriendsModel(service: MapleAPI(http: http), clock: { clock.now })
        let refresh = Task { try await friends.refresh() }; await started.wait()
        friends.listening(ListeningEvent(id: "friend", listening: Listening(current: Fixture.current(), lastPlayed: nil)))
        let received = clock.now; clock.advance(10)
        await release.open(); try await refresh.value
        #expect(friends.hasLoaded && friends.friend(id: "friend")?.listening?.current != nil)
        #expect(friends.listeningReceivedAt["friend"] == received)
        try await friends.refresh()
        #expect(friends.friend(id: "friend")?.listening?.current == nil)
        #expect(friends.listeningReceivedAt["friend"] == clock.now)
    }
}
