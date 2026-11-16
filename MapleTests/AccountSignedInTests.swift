import Foundation
import Testing
import AuthenticationServices
@testable import Maple

@MainActor
struct AccountProfileTests {
    @Test func displayNameIsTrimmedSavedAndRefreshed() async {
        let api = FakeProfileAPI(); let session = FakeSecurityService()
        let model = ProfileModel(api: api, session: session)
        #expect(await model.saveDisplayName("  Ada Lovelace "))
        #expect(await api.names == ["Ada Lovelace"])
        #expect(session.refreshes == 1)
    }

    @Test func invalidDisplayNameIsNotSent() async {
        let api = FakeProfileAPI()
        let model = ProfileModel(api: api, session: FakeSecurityService())
        #expect(await model.saveDisplayName("   ") == false)
        #expect(model.nameError == "Display name is required.")
        #expect(await model.saveDisplayName(String(repeating: "x", count: 65)) == false)
        #expect(await api.names.isEmpty)
    }

    @Test func visibilityRevertsAndExplainsOnFailure() async {
        let api = FakeProfileAPI(); let session = FakeSecurityService()
        await api.fail(visibility: URLError(.notConnectedToInternet))
        let model = ProfileModel(api: api, session: session)
        #expect(model.sharesListening)
        await model.setSharesListening(false)
        #expect(await api.visibilities == [.private])
        #expect(model.sharesListening, "Toggle returns to the server value")
        #expect(model.alertMessage == "You’re offline. Check your connection and try again.")
    }

    @Test func visibilityFollowsServerAfterSuccess() async {
        let api = FakeProfileAPI(); let session = FakeSecurityService()
        session.onRefresh = { session.user = Fixture.user(visibility: .private) }
        let model = ProfileModel(api: api, session: session)
        await model.setSharesListening(false)
        model.syncFromUser()
        #expect(!model.sharesListening && model.alertMessage == nil)
    }

    @Test func photoFailuresAreVisible() async {
        let api = FakeProfileAPI()
        await api.fail(avatar: Fixture.error(400, error: "Upload a JPG, PNG or GIF image."))
        let model = ProfileModel(api: api, session: FakeSecurityService())
        await model.uploadPhoto(Data([1, 2, 3]))
        #expect(model.alertMessage == "Choose a JPEG, PNG or GIF image.")
        await model.uploadPhoto(nil)
        #expect(model.alertMessage == "That photo couldn’t be loaded. Choose a different one.")
        await api.fail(avatar: Fixture.error(413, error: "File size exceeds 3MB limit."))
        await model.uploadPhoto(Data([1]))
        #expect(model.alertMessage == "Choose an image smaller than 3 MB.")
    }

    @Test func unauthorizedSignsOutInsteadOfShowingAnError() async {
        let api = FakeProfileAPI(); let session = FakeSecurityService()
        await api.fail(name: Fixture.error(401, message: "Unauthorized"))
        let model = ProfileModel(api: api, session: session)
        #expect(await model.saveDisplayName("Ada") == false)
        #expect(session.invalidations == 1)
        #expect(model.nameError == nil)
    }
}

@MainActor
struct AccountSecurityTests {
    @Test func changePasswordRevokesOtherDevicesByDefault() async {
        let session = FakeSecurityService()
        let model = ChangePasswordModel(session: session)
        #expect(model.signOutOtherDevices)
        model.currentPassword = "OldPass123"; model.newPassword = "NewPass123"
        await model.submit()
        #expect(session.passwordChanges.first?.revoke == true)
        #expect(model.didChange && model.currentPassword.isEmpty && model.newPassword.isEmpty)
    }

    @Test func changePasswordValidatesAndMapsWrongCurrentPassword() async {
        let session = FakeSecurityService()
        session.changePasswordError = Fixture.error(400, code: "INVALID_PASSWORD", message: "Invalid password")
        let model = ChangePasswordModel(session: session)
        model.currentPassword = "Same1234"; model.newPassword = "Same1234"
        #expect(model.newError == "Choose a password that’s different from your current one.")
        model.newPassword = "weak"
        #expect(model.newError == "Password must be at least 8 characters.")
        model.newPassword = "Better123"; model.signOutOtherDevices = false
        await model.submit()
        #expect(session.passwordChanges.first?.revoke == false)
        #expect(model.currentError == "Your current password is incorrect.")
        #expect(!model.didChange && !model.canSubmit)
        model.currentPassword = "Retyped123"
        #expect(model.currentError == nil && model.canSubmit)
    }

    @Test func changeEmailRejectsSameAddressAndConfirmsTarget() async {
        let session = FakeSecurityService()
        let model = ChangeEmailModel(currentEmail: "me@example.com", session: session)
        model.newEmail = "ME@example.com"
        #expect(model.error == "That’s already your email address.")
        model.newEmail = "new@example.com"
        await model.submit()
        #expect(session.changedEmails == ["new@example.com"])
        #expect(model.sentTo == "new@example.com")
    }

    @Test func sessionsMarkThisDeviceAndKeepTokensPrivate() async {
        let session = FakeSecurityService()
        session.sessions = [
            Fixture.session("s-old", token: "t-old", agent: "Mozilla/5.0 (Windows NT 10.0) Chrome/130.0 Safari/537.36", updated: 100),
            Fixture.session("s-current", token: "t-current", agent: "Maple/1 CFNetwork/1 Darwin/24", updated: 50),
            Fixture.session("s-new", token: "t-new", agent: "Mozilla/5.0 (Macintosh) Version/18 Safari/605", updated: 300),
        ]
        let model = SessionsModel(session: session)
        await model.load()
        #expect(model.current?.id == "s-current")
        #expect(model.current?.device.title == "Maple for iOS")
        #expect(model.others.map(\.id) == ["s-new", "s-old"], "Most recently active first")
        #expect(String(describing: model.rows).contains("t-old") == false)

        await model.revoke(model.current!)
        #expect(session.revokedTokens.isEmpty, "This device is signed out with Sign Out, not revoked from the list")
        await model.revoke(model.others[1])
        #expect(session.revokedTokens == ["t-old"])
        #expect(model.rows.map(\.id) == ["s-current", "s-new"])
    }

    @Test func sessionsLoadErrorAndSessionLoss() async {
        let session = FakeSecurityService()
        session.listError = URLError(.notConnectedToInternet)
        let model = SessionsModel(session: session)
        await model.load()
        #expect(!model.hasLoaded && model.errorMessage == "You’re offline. Check your connection and try again.")
        session.listError = Fixture.error(401)
        await model.load()
        #expect(session.invalidations == 1)
    }

    @Test func signOutEverywhereReportsFailure() async {
        let session = FakeSecurityService()
        let model = SessionsModel(session: session)
        await model.signOutEverywhere()
        #expect(session.signedOutEverywhere == 1 && model.errorMessage == nil)
        session.everywhereError = Fixture.error(500)
        await model.signOutEverywhere()
        #expect(model.errorMessage == "Maple is unavailable right now. Try again shortly.")
    }

    @Test func deleteRequiresTypedUsername() async {
        let session = FakeSecurityService()
        let model = DeleteAccountModel(username: "Tester", session: session)
        #expect(!model.canDelete)
        #expect(await model.delete() == false)
        model.confirmation = "teste"
        #expect(!model.canDelete)
        model.confirmation = " tester "
        #expect(model.canDelete)
        #expect(await model.delete())
        #expect(session.deletions == 1)
    }

    @Test func deleteFailureIsShown() async {
        let session = FakeSecurityService()
        session.deleteError = URLError(.timedOut)
        let model = DeleteAccountModel(username: "tester", session: session)
        model.confirmation = "tester"
        #expect(await model.delete() == false)
        #expect(model.errorMessage == "Maple took too long to respond. Try again.")
    }

    @Test func securityLoadsEmail() async {
        let session = FakeSecurityService()
        let model = SecurityModel(session: session)
        await model.load()
        #expect(model.email == "t@example.test")
        session.currentReply = nil
        await model.load()
        #expect(session.invalidations == 1, "No session means signed out")
    }
}

@MainActor
struct AccountPasskeyTests {
    @Test func cancellationIsSilentAndDomainFailureIsExplained() {
        let cancelled = NSError(domain: ASAuthorizationError.errorDomain, code: ASAuthorizationError.Code.canceled.rawValue)
        #expect(PasskeySupport.message(for: cancelled, purpose: .signIn) == nil)
        let notAssociated = NSError(domain: ASAuthorizationError.errorDomain, code: ASAuthorizationError.Code.failed.rawValue,
                                    userInfo: [NSLocalizedDescriptionKey: "Application with identifier ZNZ64553FT.dev.hammerpot.Maple-iOS is not associated with domain maple.music"])
        #expect(PasskeySupport.message(for: notAssociated, purpose: .register)?.contains("aren’t available") == true)
        let other = NSError(domain: ASAuthorizationError.errorDomain, code: ASAuthorizationError.Code.failed.rawValue)
        #expect(PasskeySupport.message(for: other, purpose: .signIn) == "Passkey sign-in did not finish.")
        #expect(PasskeySupport.message(for: other, purpose: .register) == "The passkey was not added.")
    }

    @Test func promptStaysOffWhileDisabled() async {
        let service = FakePasskeyService()
        let defaults = UserDefaults(suiteName: "AccountPasskeyTests")!
        defaults.removePersistentDomain(forName: "AccountPasskeyTests")
        let model = PasskeyPromptModel(service: service, defaults: defaults)
        await model.check(userID: "me")
        #expect(!model.isPresented)
        #expect(defaults.string(forKey: PasskeyPromptModel.key(for: "me")) == nil)
    }

    @Test func passkeyListNamesFallBack() {
        #expect(PasskeyItem(id: "1", name: nil, createdAt: .now).displayName == "Passkey")
        #expect(PasskeyItem(id: "1", name: "  ", createdAt: .now).displayName == "Passkey")
        #expect(PasskeyItem(id: "1", name: "iPhone", createdAt: .now).displayName == "iPhone")
    }

    @Test func removingAPasskeyUpdatesTheList() async {
        let service = FakePasskeyService()
        service.items = [PasskeyItem(id: "a", name: "A", createdAt: .distantPast), PasskeyItem(id: "b", name: "B", createdAt: .now)]
        let model = PasskeysModel(service: service)
        await model.load()
        #expect(model.items.map(\.id) == ["b", "a"])
        await model.delete(model.items[0])
        #expect(model.items.map(\.id) == ["a"])
        #expect(model.statusMessage == "Passkey removed.")
    }
}
