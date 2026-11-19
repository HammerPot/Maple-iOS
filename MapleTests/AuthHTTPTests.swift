import Foundation
import Testing
import BetterAuth
import Security
import AuthenticationServices
@testable import Maple

@MainActor
struct AuthHTTPTests {
    @Test(arguments: [401, 403]) func sessionRejection(_ status: Int) async throws {
        let rejected = Locked(false)
        let http = try testHTTP { request in
            if rejected.read() { return StubReply("Unauthorized", status: status, headers: ["Content-Type": "text/plain"]) }
            return signedInReply(request)
        }
        let model = AuthSessionModel(api: MapleAPI(http: http))
        await model.restore()
        #expect(model.user != nil)
        rejected.update { $0 = true }
        _ = try? await http.raw("user/friends/me")
        #expect((model.user == nil) == (status == 401))
        #expect((http.sessionToken == nil) == (status == 401))
        await model.invalidate()
    }
    /// Session middleware may expire its cookie as it rejects the request; that still ends this session.
    @Test func aCurrent401ThatDeletesTheCookieAlsoClearsSignedInState() async throws {
        let rejected = Locked(false)
        let http = try testHTTP { request in
            if rejected.read() {
                return StubReply(#"{"code":"UNAUTHORIZED","message":"Unauthorized"}"#, status: 401,
                                 headers: ["Set-Cookie": "__Secure-maple.session_token=; Path=/; Secure; Max-Age=0"])
            }
            return signedInReply(request)
        }
        let model = AuthSessionModel(api: MapleAPI(http: http)); await model.restore()
        #expect(model.user != nil)
        rejected.update { $0 = true }
        _ = try? await http.raw("api/auth/list-sessions")
        #expect(model.user == nil); #expect(http.sessionToken == nil)
    }

    @Test func restoring401ClearsSessionButWrongCredentialsDoNot() async throws {
        let http = try testHTTP { _ in StubReply("Unauthorized", status: 401) }
        let model = AuthSessionModel(api: MapleAPI(http: http))
        _ = try? await http.raw("api/auth/sign-in/username", method: "POST")
        #expect(http.sessionToken != nil)
        await model.restore()
        #expect(http.sessionToken == nil)
        #expect(!model.sessionUnreachable)
        #expect(!model.isRestoring)
    }
    @Test func late401CannotSignOutNewSession() async throws {
        let sent = TestGate(); let release = TestGate()
        let http = try testHTTP { _ in await sent.open(); await release.wait(); return StubReply(status: 401) }
        let model = AuthSessionModel(api: MapleAPI(http: http))
        let request = Task { _ = try? await http.raw("get/me") }
        await sent.wait()
        try http.cookies.setCookie("__Secure-maple.session_token=new-session; Path=/; Secure", for: MapleHTTP.baseURL)
        await release.open(); await request.value
        #expect(http.sessionToken == "new-session")
        // Also covers the second token check after hopping to the model's actor.
        await model.handleUnauthorized(token: "test-session")
        #expect(http.sessionToken == "new-session")
        await model.invalidate()
    }
    @Test func signOutClearsLocallyBeforeServerCompletesAndFencesNewCookie() async throws {
        let sent = TestGate(); let release = TestGate(); let captured = Locked<URLRequest?>(nil)
        let http = try testHTTP { request in
            if request.url?.path == "/api/auth/sign-out" {
                captured.update { $0 = request }; await sent.open(); await release.wait()
                return StubReply(status: 503, headers: ["Set-Cookie": "__Secure-maple.session_token=; Max-Age=0; Path=/; Secure"])
            }
            return signedInReply(request)
        }
        let model = AuthSessionModel(api: MapleAPI(http: http))
        await model.restore()
        let signingOut = Task { try await model.signOut() }
        await sent.wait()
        #expect(model.user == nil); #expect(http.sessionToken == nil)
        #expect(captured.read()?.value(forHTTPHeaderField: "Cookie")?.contains("test-session") == true)
        try http.cookies.setCookie("__Secure-maple.session_token=new-session; Path=/; Secure", for: MapleHTTP.baseURL)
        await release.open(); try await signingOut.value
        #expect(http.sessionToken == "new-session")
        await model.invalidate()
    }
    @Test func signOutOfflineStillClearsState() async throws {
        let offline = Locked(false)
        let http = try testHTTP { request in
            if offline.read() { throw URLError(.notConnectedToInternet) }
            return signedInReply(request)
        }
        let model = AuthSessionModel(api: MapleAPI(http: http)); await model.restore()
        offline.update { $0 = true }
        try await model.signOut()
        #expect(model.user == nil); #expect(http.sessionToken == nil)
    }
    @Test(arguments: [0, 403, 503]) func unavailableRestoreRetriesOnForeground(_ status: Int) async throws {
        let available = Locked(false)
        let sleeper = TestSleeper()
        let http = try testHTTP { request in
            if available.read() { return signedInReply(request) }
            if status == 0 { throw URLError(.notConnectedToInternet) }
            return StubReply(status: status)
        }
        let model = AuthSessionModel(api: MapleAPI(http: http), sleep: { try await sleeper.sleep($0) })
        await model.restore(); await sleeper.waitForSleep()
        #expect(model.sessionUnreachable); #expect(model.isRestoring)
        #expect(http.sessionToken == "test-session")
        available.update { $0 = true }
        await model.sceneBecameActive()
        #expect(model.user != nil); #expect(!model.sessionUnreachable); #expect(!model.isRestoring)
        await model.invalidate()
    }
    @Test func automaticRestoreBackoffRecoversAndStops() async throws {
        let attempts = Locked(0); let sleeper = TestSleeper(); let restored = TestGate()
        let http = try testHTTP { request in
            let n = attempts.update { value in value += 1; return value }
            if n <= 2 { throw URLError(.notConnectedToInternet) }
            return signedInReply(request)
        }
        let model = AuthSessionModel(api: MapleAPI(http: http), retryDelays: [.seconds(2), .seconds(5)], sleep: { try await sleeper.sleep($0) })
        model.didChange = { Task { await restored.open() } }
        await model.restore(); await sleeper.waitForSleep(); await sleeper.advance()
        await sleeper.waitForSleep(); await sleeper.advance(); await restored.wait()
        #expect(model.user != nil); #expect(await sleeper.delays == [.seconds(2), .seconds(5)])
        await model.invalidate()
    }
    @Test func noStoredSessionDoesNotContactServer() async throws {
        let http = try testHTTP(token: nil) { _ in Issue.record("Unexpected HTTP request"); throw URLError(.badURL) }
        let model = AuthSessionModel(api: MapleAPI(http: http)); await model.restore()
        #expect(!model.isRestoring); #expect(!model.sessionUnreachable)
    }
    @Test func nullSessionClearsStoredCookie() async throws {
        let http = try testHTTP { _ in StubReply("null") }
        let model = AuthSessionModel(api: MapleAPI(http: http)); await model.restore()
        #expect(http.sessionToken == nil); #expect(!model.sessionUnreachable)
    }
    @Test func errorsRejectHTMLLongOrUntypedText() {
        for (body, type) in [("<!doctype html><html>proxy error</html>", "text/html"), (String(repeating: "a", count: 1000), "text/plain"), ("proxy body", "application/octet-stream")] {
            let error = MapleError.response(status: 502, data: Data(body.utf8), contentType: type)
            #expect(error.message == nil); #expect(error.localizedDescription == MapleError(status: 502).localizedDescription)
        }
        #expect(MapleError.response(status: 400, data: Data("Short explanation".utf8), contentType: "text/plain; charset=utf-8").message == "Short explanation")
    }
    @Test func originAndMultipartAreCorrect() async throws {
        let requests = Locked<[URLRequest]>([])
        let http = try testHTTP { request in requests.update { $0.append(request) }; return StubReply(#"{"message":"ok"}"#) }
        _ = try await http.raw("get/me")
        _ = try await http.image(at: URL(string: "https://cdn.example.test/image")!)
        #expect(requests.read()[0].value(forHTTPHeaderField: "Origin") == MapleHTTP.origin)
        #expect(requests.read()[1].value(forHTTPHeaderField: "Origin") == nil)
        #expect(requests.read()[1].value(forHTTPHeaderField: "Cookie") == nil)
    }
    @Test func profileLookupEscapesEachUserSegmentExactlyOnce() async throws {
        let urls = Locked<[String]>([])
        let http = try testHTTP { request in
            urls.update { $0.append(request.url?.absoluteString ?? "") }
            return StubReply(#"{"id":"user","username":"unit","name":null,"pfp":null}"#)
        }
        _ = try? await MapleAPI(http: http).profile(username: "a b/c..%?#")
        let url = try #require(urls.read().first)
        // A slash, dot segment, percent, query or fragment in a username stays inside the one path segment.
        #expect(url == MapleHTTP.origin + "/public/get/user/a%20b%2Fc%2E%2E%25%3F%23")
    }
    @Test func booleanQueriesUseWordsAndKeepNumbers() {
        let query = BetterAuthHTTP.queryItems(from: ["enabled": NSNumber(value: true), "disabled": NSNumber(value: false), "limit": NSNumber(value: 1), "empty": NSNull()])
        #expect(Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") }) == ["enabled": "true", "disabled": "false", "limit": "1"])
    }
    @Test func freshInstallWipesOnlyItsKeychainServiceOnce() throws {
        let suite = "MapleTests.\(UUID())"; let service = "MapleTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        }
        let storage = MapleKeychainStorage(service: service)
        _ = try storage.save(key: "cookie", value: "old")
        #expect(MapleKeychainStorage.wipeIfFreshInstall(defaults: defaults, service: service))
        #expect(storage.get(key: "cookie") == nil)
        _ = try storage.save(key: "cookie", value: "new")
        #expect(!MapleKeychainStorage.wipeIfFreshInstall(defaults: defaults, service: service))
        #expect(storage.get(key: "cookie") == "new")
    }
    @Test func swallowedCookiePersistenceFailureIsSurfaced() throws {
        let errors = Locked<[MapleError]>([])
        let storage = MapleKeychainStorage(service: "MapleTests.\(UUID())", onSaveFailure: { error in errors.update { $0.append(error) } }, addItem: { _ in errSecInteractionNotAllowed })
        let jar = CookieStorage(storage: storage)
        try jar.setCookie("__Secure-maple.session_token=unit; Path=/; Secure", for: MapleHTTP.baseURL)
        #expect(errors.read().count == 1); #expect(errors.read().first?.code == "KEYCHAIN_\(errSecInteractionNotAllowed)")
        #expect(jar.cookies?.count == 1)
    }
    @Test func cancelledPasskeyDoesNotToast() {
        let toasts = ToastCenter()
        toasts.show(CancellationError())
        #expect(toasts.notice == nil)
    }
}
