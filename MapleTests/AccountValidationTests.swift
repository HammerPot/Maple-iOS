import Foundation
import Testing
@testable import Maple

struct AccountValidationTests {
    @Test(arguments: [
        ("a", "Username must be at least 2 characters."),
        (String(repeating: "a", count: 33), "Username must be at most 32 characters."),
        ("has space", "Username may only use letters, digits, dots, dashes and underscores."),
        ("émile", "Username may only use letters, digits, dots, dashes and underscores."),
    ])
    func invalidUsernames(_ value: String, _ message: String) {
        #expect(AccountRules.usernameProblem(value) == message)
    }

    @Test(arguments: ["ab", "Maple.User_1-x", String(repeating: "z", count: 32)])
    func validUsernames(_ value: String) { #expect(AccountRules.usernameProblem(value) == nil) }

    @Test(arguments: [
        ("Short1", "Password must be at least 8 characters."),
        ("A" + String(repeating: "a", count: 128), "Password must be at most 128 characters."),
        ("lowercase only", "Password needs an uppercase letter."),
        ("UPPERCASE ONLY", "Password needs a lowercase letter."),
    ])
    func invalidPasswords(_ value: String, _ message: String) {
        #expect(AccountRules.passwordProblem(value) == message)
    }

    @Test func validPasswordNeedsNoDigitOrSymbol() { #expect(AccountRules.passwordProblem("CorrectHorse") == nil) }

    @Test(arguments: ["person@example.com", "first.last+tag@sub.example.co.uk", "a_b@x.io"])
    func validEmails(_ value: String) { #expect(AccountRules.isEmail(value)) }

    @Test(arguments: ["user", "user@", "@example.com", ".dot@example.com", "two..dots@example.com", "a@b", "a@b.c",
                      String(repeating: "a", count: 250) + "@x.io"])
    func invalidEmails(_ value: String) {
        #expect(!AccountRules.isEmail(value))
        #expect(AccountRules.emailProblem(value) == "Enter a valid email address.")
    }

    @Test func displayNameIsTrimmedAndBounded() {
        #expect(AccountRules.displayNameProblem("   ") == "Display name is required.")
        #expect(AccountRules.displayNameProblem("  Ada  ") == nil)
        #expect(AccountRules.displayNameProblem(String(repeating: "n", count: 64)) == nil)
        #expect(AccountRules.displayNameProblem(String(repeating: "n", count: 65)) == "Display name must be at most 64 characters.")
    }
}

struct AccountErrorCopyTests {
    @Test(arguments: [
        ("INVALID_USERNAME_OR_PASSWORD", "The username or password is incorrect."),
        ("INVALID_EMAIL_OR_PASSWORD", "The email or password is incorrect."),
        ("USERNAME_IS_ALREADY_TAKEN", "That username is already taken."),
        ("EMAIL_UNAVAILABLE", "That email is used by another account. Use a different email address."),
        ("ALREADY_ENROLLED", "This account has already been moved. Sign in instead."),
        ("ENROLLMENT_CHANGED", "This account changed while it was being moved. Try again."),
        ("ENROLLMENT_FAILED", "Your account couldn’t be moved. Try again."),
        ("INVALID_PASSWORD", "Your current password is incorrect."),
    ])
    func betterAuthCodesHavePlainCopy(_ code: String, _ expected: String) {
        #expect(AccountErrorCopy.message(for: Fixture.error(400, code: code, message: "server text")) == expected)
    }

    @Test func serverPolicyMessageIsKeptWhenHuman() {
        let error = Fixture.error(400, code: "PASSWORD_POLICY", message: "Password needs an uppercase letter.")
        #expect(AccountErrorCopy.message(for: error) == "Password needs an uppercase letter.")
    }

    @Test(arguments: [
        ("You cannot friend your own account.", "You can’t add yourself as a friend."),
        ("You are already friends.", "You’re already friends."),
        ("Friend request already sent.", "You’ve already sent this person a request."),
        ("This user already sent you a friend request.", "This person already sent you a request. Accept it in Friend Requests."),
        ("User not found", "No one on Maple uses that username."),
    ])
    func friendRouterErrorsAreReworded(_ server: String, _ expected: String) {
        #expect(AccountErrorCopy.message(for: Fixture.error(409, error: server)) == expected)
    }

    @Test func transportAndStatusFallbacks() {
        #expect(AccountErrorCopy.message(for: URLError(.notConnectedToInternet)) == "You’re offline. Check your connection and try again.")
        #expect(AccountErrorCopy.isOffline(URLError(.networkConnectionLost)))
        #expect(AccountErrorCopy.message(for: URLError(.timedOut)) == "Maple took too long to respond. Try again.")
        #expect(AccountErrorCopy.message(for: Fixture.error(429, message: "Too many requests. Please try again later.")) == "Too many attempts. Wait a minute and try again.")
        #expect(AccountErrorCopy.message(for: Fixture.error(401, message: "Unauthorized")) == "Your session has ended. Sign in again.")
        #expect(AccountErrorCopy.message(for: Fixture.error(502, message: "<html>Bad gateway</html>")) == "Maple is unavailable right now. Try again shortly.")
        #expect(AccountErrorCopy.message(for: CancellationError()) == nil)
        #expect(AccountErrorCopy.message(for: URLError(.cancelled)) == nil)
    }

    @Test func rawBodiesAreNeverShown() {
        let error = Fixture.error(400, message: #"{"token":"secret-value"}"#)
        #expect(AccountErrorCopy.message(for: error) == AccountErrorCopy.generic)
    }

    @Test func onlyUnauthorizedEndsTheSession() {
        #expect(AccountErrorCopy.endsSession(Fixture.error(401)))
        #expect(!AccountErrorCopy.endsSession(Fixture.error(403, code: "SESSION_EXPIRED")))
        #expect(!AccountErrorCopy.endsSession(URLError(.notConnectedToInternet)))
    }
}

struct AccountDeviceDescriptionTests {
    @Test(arguments: [
        ("Maple/1 CFNetwork/3826.500.111.2.2 Darwin/24.4.0", "Maple for iOS", "iphone"),
        ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15", "Safari on Mac", "laptopcomputer"),
        ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36", "Chrome on Windows", "pc"),
        ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0", "Edge on Windows", "pc"),
        ("Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) FxiOS/132.0 Mobile/15E148 Safari/605.1.15", "Firefox on iPhone", "iphone"),
        ("Mozilla/5.0 (X11; Linux x86_64; rv:132.0) Gecko/20100101 Firefox/132.0", "Firefox on Linux", "desktopcomputer"),
        ("Mozilla/5.0 (iPad; CPU OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1", "Safari on iPad", "ipad"),
        ("curl/8.7.1", "Other Device", "network"),
    ])
    func userAgentsAreDescribed(_ agent: String, _ title: String, _ symbol: String) {
        let device = DeviceDescription(userAgent: agent)
        #expect(device.title == title)
        #expect(device.systemImage == symbol)
    }

    @Test func missingUserAgentIsUnknown() {
        #expect(DeviceDescription(userAgent: nil).title == "Unknown Device")
        #expect(DeviceDescription(userAgent: "  ").title == "Unknown Device")
    }
}
