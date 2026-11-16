import Foundation
import Testing
@testable import Maple

@MainActor
struct AccountSignInTests {
    @Test func submitNeedsBothFields() {
        let model = SignInModel(session: FakeSignInService())
        #expect(!model.canSubmit)
        model.identifier = "  "; model.password = "x"
        #expect(!model.canSubmit)
        model.identifier = "tester"
        #expect(model.canSubmit)
    }

    @Test func successClearsPasswordAndTrimsOnlyEmails() async {
        let session = FakeSignInService()
        let model = SignInModel(session: session)
        model.identifier = "  person@example.com "; model.password = "Secret123"
        await model.signIn()
        #expect(session.signIns.first?.identifier == "person@example.com")
        #expect(model.password.isEmpty)
        #expect(model.errorMessage == nil && model.route == nil)

        model.identifier = "legacy name"; model.password = "pw"
        await model.signIn()
        #expect(session.signIns.last?.identifier == "legacy name")
    }

    @Test func unverifiedUsernameGoesToVerificationWithCredentials() async {
        let session = FakeSignInService()
        session.signInResults = [Fixture.error(403, code: "EMAIL_NOT_VERIFIED", message: "Email is not verified")]
        let model = SignInModel(session: session)
        model.identifier = "tester"; model.password = "Secret123"
        await model.signIn()
        guard case .verify(let context) = model.route else { Issue.record("Expected verification route"); return }
        #expect(context.username == "tester" && context.email == nil)
        #expect(context.password == "Secret123" && context.origin == .signIn)
        #expect(context.canSignIn && context.canChangeEmail)
        #expect(model.password.isEmpty && model.errorMessage == nil)
    }

    @Test func unverifiedEmailCannotChangeAddress() async {
        let session = FakeSignInService()
        session.signInResults = [Fixture.error(403, code: "EMAIL_NOT_VERIFIED")]
        let model = SignInModel(session: session)
        model.identifier = "person@example.com"; model.password = "Secret123"
        await model.signIn()
        guard case .verify(let context) = model.route else { Issue.record("Expected verification route"); return }
        #expect(context.email == "person@example.com" && context.username == nil)
        #expect(context.canSignIn && !context.canChangeEmail)
    }

    @Test func legacyAccountGoesToEnrollment() async {
        let session = FakeSignInService()
        session.signInResults = [Fixture.error(403, code: "LEGACY_ENROLLMENT_REQUIRED")]
        let model = SignInModel(session: session)
        model.identifier = "OldTimer"; model.password = "weak"
        await model.signIn()
        #expect(model.route == .legacy(LegacyContext(username: "OldTimer", password: "weak", fromSignIn: true)))
    }

    @Test(arguments: [
        (Fixture.error(401, code: "INVALID_USERNAME_OR_PASSWORD"), "The username or password is incorrect."),
        (Fixture.error(429), "Too many attempts. Wait a minute and try again."),
    ] as [(MapleError, String)])
    func failuresStayOnScreen(_ error: MapleError, _ message: String) async {
        let session = FakeSignInService()
        session.signInResults = [error]
        let model = SignInModel(session: session)
        model.identifier = "tester"; model.password = "Wrong123"
        await model.signIn()
        #expect(model.errorMessage == message)
        #expect(model.route == nil)
        #expect(model.password == "Wrong123")
        #expect(session.invalidations == 0, "A wrong password is not a lost session")
    }

    @Test func offlineIsExplained() async {
        let session = FakeSignInService()
        session.signInResults = [URLError(.notConnectedToInternet)]
        let model = SignInModel(session: session)
        model.identifier = "tester"; model.password = "pw"
        await model.signIn()
        #expect(model.errorMessage == "You’re offline. Check your connection and try again.")
    }

    @Test func passkeySignInIsInertWhileDisabled() async {
        #expect(PasskeySupport.isEnabled == false)
        let session = FakeSignInService()
        session.passkeyError = URLError(.badServerResponse)
        let model = SignInModel(session: session)
        await model.signInWithPasskey()
        #expect(model.errorMessage == nil)
    }
}

@MainActor
struct AccountRegisterTests {
    @Test func submitWaitsForEveryFieldToBeValid() {
        let model = RegisterModel(session: FakeSignInService())
        model.email = "person@example.com"; model.username = "x"; model.password = "Secret123"
        #expect(model.usernameError == "Username must be at least 2 characters.")
        #expect(!model.canSubmit)
        model.username = "newuser"
        #expect(model.canSubmit)
        model.password = "secret123"
        #expect(model.passwordError == "Password needs an uppercase letter.")
        #expect(!model.canSubmit)
    }

    @Test func emptyFieldsShowNoError() {
        let model = RegisterModel(session: FakeSignInService())
        #expect(model.emailError == nil && model.usernameError == nil && model.passwordError == nil)
    }

    @Test func successMovesToVerificationKeepingCredentialsInMemory() async {
        let session = FakeSignInService()
        let model = RegisterModel(session: session)
        model.email = " Person@Example.com "; model.username = "newuser"; model.password = "Secret123"
        await model.register()
        #expect(session.signUps.first?.email == "Person@Example.com")
        #expect(model.verification == VerificationContext(email: "Person@Example.com", username: "newuser", password: "Secret123", origin: .register))
        #expect(model.password.isEmpty)
    }

    @Test func takenUsernameIsShownOnThatField() async {
        let session = FakeSignInService()
        session.signUpError = Fixture.error(400, code: "USERNAME_IS_ALREADY_TAKEN", message: "Username is already taken. Please try another.")
        let model = RegisterModel(session: session)
        model.email = "person@example.com"; model.username = "taken"; model.password = "Secret123"
        await model.register()
        #expect(model.usernameError == "That username is already taken.")
        #expect(model.verification == nil && !model.canSubmit)
        model.username = "untaken"
        #expect(model.usernameError == nil && model.canSubmit)
    }

    @Test func existingEmailIsShownOnEmailField() async {
        let session = FakeSignInService()
        session.signUpError = Fixture.error(422, code: "USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL")
        let model = RegisterModel(session: session)
        model.email = "person@example.com"; model.username = "newuser"; model.password = "Secret123"
        await model.register()
        #expect(model.emailError == "An account already uses that email. Sign in, or use a different email.")
    }
}

@MainActor
struct AccountVerifyEmailTests {
    private func makeModel(_ context: VerificationContext, session: FakeSignInService, clock: TestClock,
                           sleep: @escaping (Duration) async throws -> Void = { _ in }) -> VerifyEmailModel {
        VerifyEmailModel(context: context, session: session, clock: { clock.now }, sleep: sleep)
    }
    private let registered = VerificationContext(email: "new@example.com", username: "newuser", password: "Secret123", origin: .register)

    @Test func checkIsSideEffectFreeAndDetectsVerification() async {
        let session = FakeSignInService(); let clock = TestClock()
        session.verifiedResults = [.success(false), .failure(URLError(.notConnectedToInternet)), .success(true)]
        let model = makeModel(registered, session: session, clock: clock)
        await model.check(); #expect(!model.isVerified)
        await model.check(); #expect(!model.isVerified && model.errorMessage == nil, "Background checks stay quiet")
        await model.check(); #expect(model.isVerified)
        #expect(session.signIns.isEmpty && session.resent.isEmpty, "Polling never signs in or resends")
    }

    @Test func pollRunsOnIntervalUntilVerified() async {
        let session = FakeSignInService(); let clock = TestClock()
        session.verifiedResults = [.success(false), .success(false), .success(true)]
        var sleeps: [Duration] = []
        let model = makeModel(registered, session: session, clock: clock) { sleeps.append($0) }
        await model.poll()
        #expect(model.isVerified)
        #expect(session.verifiedChecks == 3)
        #expect(sleeps == [VerifyEmailModel.pollInterval, VerifyEmailModel.pollInterval, VerifyEmailModel.pollInterval])
        #expect(VerifyEmailModel.pollInterval == .seconds(5))
    }

    @Test func pollStopsWhenCancelled() async {
        let session = FakeSignInService(); let clock = TestClock()
        let model = makeModel(registered, session: session, clock: clock) { _ in throw CancellationError() }
        await model.poll()
        #expect(session.verifiedChecks == 0 && !model.isVerified)
    }

    @Test func resendHasCooldownAfterTheInitialEmail() async {
        let session = FakeSignInService(); let clock = TestClock()
        let model = makeModel(registered, session: session, clock: clock)
        #expect(model.secondsUntilResend(at: clock.now) == 60)
        #expect(!model.canResend)
        await model.resend()
        #expect(session.resent.isEmpty)
        clock.advance(59.2)
        #expect(model.secondsUntilResend(at: clock.now) == 1)
        clock.advance(1)
        #expect(model.canResend)
        await model.resend()
        #expect(session.resent == ["new@example.com"])
        #expect(model.statusMessage == "We sent another link.")
        #expect(model.secondsUntilResend(at: clock.now) == 60, "Cooldown restarts after each send")
    }

    @Test func resendWithoutAnAddressSignsInAgain() async {
        let session = FakeSignInService(); let clock = TestClock()
        session.signInResults = [Fixture.error(403, code: "EMAIL_NOT_VERIFIED")]
        let context = VerificationContext(email: nil, username: "tester", password: "Secret123", origin: .signIn)
        let model = makeModel(context, session: session, clock: clock)
        clock.advance(61)
        await model.resend()
        #expect(session.signIns.count == 1 && session.resent.isEmpty)
        #expect(model.statusMessage == "We sent another link.")
        #expect(!model.isVerified)
    }

    @Test func continueSignsInOnce() async {
        let session = FakeSignInService(); let clock = TestClock()
        let model = makeModel(registered, session: session, clock: clock)
        await model.continueAfterVerifying()
        #expect(session.signIns.map(\.identifier) == ["newuser"])
        #expect(model.isVerified)
    }

    @Test func continueBeforeVerifyingExplainsAndRestartsCooldown() async {
        let session = FakeSignInService(); let clock = TestClock()
        session.signInResults = [Fixture.error(403, code: "EMAIL_NOT_VERIFIED")]
        let model = makeModel(registered, session: session, clock: clock)
        clock.advance(120)
        await model.continueAfterVerifying()
        #expect(!model.isVerified)
        #expect(model.statusMessage?.hasPrefix("Your email isn’t verified yet.") == true)
        #expect(model.secondsUntilResend(at: clock.now) == 60)
    }

    @Test func withoutCredentialsTheScreenReturnsToSignIn() async {
        let session = FakeSignInService(); let clock = TestClock()
        let model = makeModel(VerificationContext(email: nil, username: nil, password: nil, origin: .session), session: session, clock: clock)
        #expect(model.canResend == false)
        await model.continueAfterVerifying()
        #expect(model.needsSignIn && session.signIns.isEmpty)
    }

    @Test func changeEmailUsesEnrollmentAndUpdatesTheAddress() async {
        let session = FakeSignInService(); let clock = TestClock()
        let model = makeModel(registered, session: session, clock: clock)
        model.newEmail = "new@example.com"
        #expect(model.newEmailProblem == "That’s the address we already sent to.")
        model.newEmail = " Fixed@Example.com "
        #expect(model.canChangeEmail)
        #expect(await model.changeEmail())
        #expect(session.enrollments == [.init(username: "newuser", password: "Secret123", email: "fixed@example.com", newUsername: nil)])
        #expect(model.context.email == "fixed@example.com")
        #expect(model.statusMessage == "We sent a new link to fixed@example.com.")
    }

    @Test func changeEmailReportsUnavailableAddress() async {
        let session = FakeSignInService(); let clock = TestClock()
        session.enrollResults = [Fixture.error(409, code: "EMAIL_UNAVAILABLE")]
        let model = makeModel(registered, session: session, clock: clock)
        model.newEmail = "used@example.com"
        #expect(await model.changeEmail() == false)
        #expect(model.changeEmailError == "That email is used by another account. Use a different email address.")
        #expect(model.context.email == "new@example.com")
    }

    @Test func changeEmailDeliveryFailureStillMovesTheAddress() async {
        let session = FakeSignInService(); let clock = TestClock()
        session.enrollResults = [Fixture.error(503, code: "EMAIL_DELIVERY_FAILED")]
        let model = makeModel(registered, session: session, clock: clock)
        model.newEmail = "fixed@example.com"
        #expect(await model.changeEmail())
        #expect(model.context.email == "fixed@example.com")
        #expect(model.errorMessage?.contains("couldn’t be sent") == true)
    }

    @Test func changeEmailIsUnavailableWithoutUsername() {
        let context = VerificationContext(email: "a@example.com", username: nil, password: "pw", origin: .signIn)
        let model = makeModel(context, session: FakeSignInService(), clock: TestClock())
        model.newEmail = "b@example.com"
        #expect(!model.canChangeEmail)
    }
}

@MainActor
struct AccountLegacyEnrollmentTests {
    @Test func replacementUsernameIsRequestedThenSent() async {
        let session = FakeSignInService()
        session.enrollResults = [Fixture.error(400, code: "USERNAME_REPLACEMENT_REQUIRED", message: "Your old username is no longer allowed. Choose a new username."), nil]
        let model = LegacyEnrollmentModel(context: LegacyContext(username: "has space", password: "pw", fromSignIn: true), session: session)
        model.email = "Old@Example.com"
        await model.enroll()
        #expect(model.needsNewUsername)
        #expect(model.errorMessage == "Your old username is no longer allowed. Choose a new one.")
        #expect(!model.canSubmit, "A valid new username is now required")
        model.newUsername = "bad name"
        #expect(model.newUsernameError == "Username may only use letters, digits, dots, dashes and underscores.")
        model.newUsername = "Spaced"
        await model.enroll()
        #expect(session.enrollments.last == .init(username: "has space", password: "pw", email: "old@example.com", newUsername: "Spaced"))
        #expect(model.verification?.username == "Spaced")
        #expect(model.verification?.notice == "Your username is now Spaced.")
        #expect(model.verification?.origin == .legacy)
    }

    @Test func emailDeliveryFailureStillContinuesToVerification() async {
        let session = FakeSignInService()
        session.enrollResults = [Fixture.error(503, code: "EMAIL_DELIVERY_FAILED")]
        let model = LegacyEnrollmentModel(context: LegacyContext(username: "OldTimer", password: "weak", fromSignIn: true), session: session)
        model.email = "old@example.com"
        await model.enroll()
        #expect(model.verification?.email == "old@example.com")
        #expect(model.verification?.notice?.contains("couldn’t be sent") == true)
    }

    @Test(arguments: [
        ("EMAIL_UNAVAILABLE", 409, "email"), ("INVALID_EMAIL", 400, "email"),
        ("USERNAME_TAKEN", 409, "username"), ("INVALID_USERNAME", 400, "username"),
        ("INVALID_LEGACY_CREDENTIALS", 401, "form"), ("ENROLLMENT_FAILED", 500, "form"), ("ENROLLMENT_CHANGED", 409, "form"),
    ])
    func errorsLandOnTheRightField(_ code: String, _ status: Int, _ place: String) async {
        let session = FakeSignInService()
        session.enrollResults = [Fixture.error(status, code: code, message: "Server copy.")]
        let model = LegacyEnrollmentModel(context: LegacyContext(username: "OldTimer", password: "weak"), session: session)
        model.email = "old@example.com"
        await model.enroll()
        switch place {
        case "email": #expect(model.emailError != nil && model.errorMessage == nil)
        case "username": #expect(model.newUsernameError != nil && model.errorMessage == nil)
        default: #expect(model.errorMessage == AccountErrorCopy.codes[code])
        }
        #expect(model.verification == nil)
        #expect(session.invalidations == 0)
    }

    @Test func alreadyEnrolledOffersSignIn() async {
        let session = FakeSignInService()
        session.enrollResults = [Fixture.error(409, code: "ALREADY_ENROLLED")]
        let model = LegacyEnrollmentModel(context: LegacyContext(username: "OldTimer", password: "weak"), session: session)
        model.email = "old@example.com"
        await model.enroll()
        #expect(model.alreadyEnrolled)
    }

    @Test func blankOriginalUsernameIsAllowed() {
        let model = LegacyEnrollmentModel(context: LegacyContext(), session: FakeSignInService())
        model.password = "pw"; model.email = "old@example.com"
        #expect(model.canSubmit)
    }
}

@MainActor
struct AccountForgotPasswordTests {
    @Test func sendsTrimmedValidEmail() async {
        let session = FakeSignInService()
        let model = ForgotPasswordModel(email: " person@example.com ", session: session)
        await model.send()
        #expect(session.resets == ["person@example.com"])
        #expect(model.sentTo == "person@example.com")
        model.startOver()
        #expect(model.sentTo == nil)
    }

    @Test func invalidEmailIsNotSent() async {
        let session = FakeSignInService()
        let model = ForgotPasswordModel(email: "person", session: session)
        #expect(model.emailError == "Enter a valid email address.")
        await model.send()
        #expect(session.resets.isEmpty)
    }

    @Test func rateLimitIsShown() async {
        let session = FakeSignInService()
        session.resetError = Fixture.error(429)
        let model = ForgotPasswordModel(email: "person@example.com", session: session)
        await model.send()
        #expect(model.errorMessage == "Too many attempts. Wait a minute and try again.")
        #expect(model.sentTo == nil)
    }
}
