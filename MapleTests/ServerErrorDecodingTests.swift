import Foundation
import Testing
import BetterAuth
import BetterAuthPasskey
@testable import Maple

@MainActor
struct ServerErrorDecodingTests {
    /// Better Auth 1.7.13 dist/api/routes/{sign-in,sign-up,session,email-verification,update-user}.mjs,
    /// dist/plugins/username/index.mjs; api/auth/auth.ts. Complements AuthWireDecodingTests' flow-specific errors.
    @Test func remainingAuthErrorsUseTheProductionErrorDecoder() async throws {
        let cases: [(String, String, Int, String)] = [
            ("POST", "sign-in/username", 422, "USERNAME_TOO_LONG"),
            ("POST", "sign-in/username", 422, "INVALID_USERNAME"),
            ("POST", "sign-in/username", 401, "FAILED_TO_CREATE_SESSION"),
            ("POST", "sign-in/email", 400, "INVALID_EMAIL"),
            ("POST", "sign-in/email", 401, "FAILED_TO_CREATE_SESSION"),
            ("POST", "sign-up/email", 400, "INVALID_EMAIL"),
            ("POST", "sign-up/email", 400, "FAILED_TO_CREATE_USER"),
            ("POST", "sign-up/email", 400, "PASSWORD_TOO_SHORT"),
            ("POST", "sign-up/email", 400, "PASSWORD_TOO_LONG"),
            ("POST", "send-verification-email", 400, "EMAIL_MISMATCH"),
            ("POST", "change-password", 400, "PASSWORD_TOO_LONG"),
            ("POST", "change-password", 500, "FAILED_TO_GET_SESSION"),
            ("GET", "get-session", 401, "FAILED_TO_GET_SESSION"),
            ("GET", "get-session", 500, "FAILED_TO_GET_SESSION"),
            ("GET", "list-sessions", 401, "UNAUTHORIZED"),
            ("POST", "revoke-session", 500, "INTERNAL_SERVER_ERROR"),
            ("POST", "revoke-sessions", 401, "UNAUTHORIZED"),
        ]
        for (method, route, status, code) in cases {
            let path = "api/auth/" + route
            let body = #"{"code":"\#(code)","message":"Request failed"}"#
            let h = try WireHarness(["\(method) /\(path)": StubReply(body, status: status)])
            do {
                _ = try await h.http.raw(path, method: method)
                Issue.record("\(route) unexpectedly succeeded")
            } catch {
                let failure = try #require(error as? MapleError)
                #expect(failure.status == status); #expect(failure.code == code)
            }
        }
    }

    /// All auth routes share origin-check, validation and rate-limit errors. Rate limits may omit code.
    /// Sources: dist/api/middlewares/origin-check.mjs; dist/api/rate-limiter/index.mjs; api/auth/auth.ts.
    @Test(arguments: ["INVALID_ORIGIN", "MISSING_OR_NULL_ORIGIN", "INVALID_CALLBACK_URL", "INVALID_REDIRECT_URL", "VALIDATION_ERROR"])
    func sharedAuthErrorsPreserveTheirCode(code: String) async throws {
        let status = code == "VALIDATION_ERROR" ? 400 : 403
        let h = try WireHarness(token: nil, ["POST /api/auth/sign-up/email": StubReply(#"{"code":"\#(code)","message":"Request rejected"}"#, status: status)])
        do {
            try await h.auth.signUp(username: "newuser", email: "new@example.test", password: "Secret123")
            Issue.record("Expected rejection")
        } catch {
            #expect((error as? MapleError)?.code == code); #expect((error as? MapleError)?.status == status)
        }
    }

    /// @better-auth/passkey 1.7.13 dist/index.mjs, plus Better Auth's resource-ownership/session middleware
    /// and Maple api/auth/auth.ts's verified-email hook. No WebAuthn ceremony or live request is performed.
    @Test func passkeyErrorsUseTheSameAdapterAsTheDisabledFeature() async throws {
        let cases: [(BetterAuthPasskeyRoute, Int, String?)] = [
            (.passkeyGenerateRegisterOptions, 401, "EMAIL_NOT_VERIFIED"),
            (.passkeyGenerateRegisterOptions, 403, "SESSION_NOT_FRESH"),
            (.passkeyGenerateRegisterOptions, 401, "SESSION_REQUIRED"),
            (.passkeyVerifyRegistration, 401, "EMAIL_NOT_VERIFIED"),
            (.passkeyVerifyRegistration, 400, "CHALLENGE_NOT_FOUND"),
            (.passkeyVerifyRegistration, 400, "FAILED_TO_VERIFY_REGISTRATION"),
            (.passkeyVerifyRegistration, 401, "YOU_ARE_NOT_ALLOWED_TO_REGISTER_THIS_PASSKEY"),
            (.passkeyVerifyRegistration, 500, "FAILED_TO_VERIFY_REGISTRATION"),
            (.passkeyGenerateAuthenticateOptions, 429, nil),
            (.passkeyVerifyAuthentication, 400, nil), // "origin missing"
            (.passkeyVerifyAuthentication, 400, "CHALLENGE_NOT_FOUND"),
            (.passkeyVerifyAuthentication, 401, "PASSKEY_NOT_FOUND"),
            (.passkeyVerifyAuthentication, 401, "AUTHENTICATION_FAILED"),
            (.passkeyVerifyAuthentication, 400, "AUTHENTICATION_FAILED"),
            (.passkeyVerifyAuthentication, 500, "UNABLE_TO_CREATE_SESSION"),
            (.passkeyVerifyAuthentication, 500, nil), // "User not found"
            (.passkeyListUserPasskeys, 401, "EMAIL_NOT_VERIFIED"),
            (.passkeyDeletePasskey, 401, "EMAIL_NOT_VERIFIED"),
            (.passkeyDeletePasskey, 404, "PASSKEY_NOT_FOUND"),
            (.passkeyDeletePasskey, 401, nil), // ownership middleware: another user's passkey
            (.passkeyUpdatePasskey, 401, "EMAIL_NOT_VERIFIED"),
            (.passkeyUpdatePasskey, 404, "PASSKEY_NOT_FOUND"),
            (.passkeyUpdatePasskey, 401, "YOU_ARE_NOT_ALLOWED_TO_REGISTER_THIS_PASSKEY"),
            (.passkeyUpdatePasskey, 500, "FAILED_TO_UPDATE_PASSKEY"),
        ]
        for (route, status, code) in cases {
            let body = code.map { #"{"code":"\#($0)","message":"Request failed"}"# } ?? #"{"message":"Request failed"}"#
            let h = try WireHarness(["\(route.method) /api/auth\(route.path)": StubReply(body, status: status)])
            do {
                let _: APIResource<PasskeyDeletePasskeyResponse, EmptyContext> = try await BetterAuthHTTP(http: h.http).perform(route: route, responseType: PasskeyDeletePasskeyResponse.self)
                Issue.record("\(route.path) unexpectedly succeeded")
            } catch {
                #expect((error as? MapleError)?.code == code); #expect((error as? MapleError)?.status == status)
            }
        }
    }

    /// api/user/{friends,manageUser}.ts, api/publicGet/get.ts, api/middleware/{session,serverError}.ts.
    /// Maple's bodies are {error}; unauthenticated responses are plain text. Raw routes include images and uploads.
    @Test func mapleRouteErrorsPreserveEveryDocumentedShape() async throws {
        let cases: [(String, String, Int, String)] = [
            ("POST", "user/friends/me/requests/f1", 400, "You cannot friend your own account."),
            ("POST", "user/friends/me/requests/f1", 404, "User not found"),
            ("POST", "user/friends/me/requests/f1", 409, "You are already friends."),
            ("POST", "user/friends/me/requests/f1", 409, "Friend request already sent."),
            ("POST", "user/friends/me/requests/f1", 409, "This user already sent you a friend request."),
            ("POST", "user/friends/me/requests/f1/accept", 404, "Friend request not found"),
            ("DELETE", "user/friends/me/requests/f1", 404, "Friend request not found"),
            ("DELETE", "user/friends/me/f1", 404, "You are not friends."),
            ("PATCH", "user/manage/me", 404, "User not found"),
            ("PATCH", "user/manage/me/listening", 400, "Visibility must be public or private."),
            ("PUT", "user/manage/me/pfp", 400, "Upload a JPG, PNG or GIF image."),
            ("PUT", "user/manage/me/pfp", 413, "File size exceeds 3MB limit."),
            ("PUT", "user/manage/me/albumArt", 400, "playbackId is invalid."),
            ("PUT", "user/manage/me/albumArt", 409, "Playback is no longer current."),
            ("GET", "public/get/user/unit", 404, "User not found"),
            ("GET", "public/get/user/id/u1", 404, "User not found"),
            ("GET", "public/get/pfp/u1", 404, "User has no pfp"),
            ("GET", "public/get/albumArt/u1/a1", 404, "User has no album art"),
            ("GET", "get/me", 403, "Untrusted origin"),
            ("GET", "get/me", 500, "Error fetching user"),
            ("POST", "user/friends/me/requests/f1", 500, "Error processing friend request"),
            ("DELETE", "user/manage/me", 500, "Error updating user"),
        ]
        for (method, path, status, message) in cases {
            let body = #"{"error":"\#(message)"}"#
            let h = try WireHarness(["\(method) /\(path)": StubReply(body, status: status)])
            do {
                _ = try await h.http.raw(path, method: method)
                Issue.record("\(path) unexpectedly succeeded")
            } catch {
                #expect((error as? MapleError)?.error == message); #expect((error as? MapleError)?.status == status)
            }
        }
    }
}
