import XCTest

final class MaplePlatformUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func selectTab(_ name: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[name].firstMatch
        if tab.exists { tab.tap(); return }
        let radio = app.radioButtons[name].firstMatch
        if radio.exists { radio.tap(); return }
        let button = app.buttons[name].firstMatch
        if button.exists { button.tap(); return }
        let item = app.staticTexts[name].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Missing navigation item: \(name)")
        item.tap()
    }

    @MainActor
    func testPlayerAndRegistrationCanBeDismissed() {
        let app = XCUIApplication()
        app.launch()
        let player = app.buttons["openNowPlaying"]
        XCTAssertTrue(player.waitForExistence(timeout: 10))
        player.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(player.waitForExistence(timeout: 5))
        selectTab("Account", in: app)
        XCTAssertTrue(app.buttons["Register"].waitForExistence(timeout: 5))
        app.buttons["Register"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["Password"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Register"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Account after dismissing registration"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testImportAndDeletionDialogsCanBeCancelled() {
        let app = XCUIApplication()
        app.launch()
        selectTab("Settings", in: app)
        let addMusic = app.buttons["Add Music"]
        XCTAssertTrue(addMusic.waitForExistence(timeout: 10))
        #if os(iOS)
        app.swipeUp()
        #endif
        addMusic.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 60))
        cancel.tap()
        let clear = app.buttons["Clear Documents"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        #if os(iOS)
        app.swipeUp()
        #endif
        clear.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(addMusic.exists)
    }
    #if os(iOS)
    @MainActor
    func testLandscapeRegistrationRemainsReachableWithLargeText() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        selectTab("Account", in: app)
        let register = app.buttons["Register"]
        XCTAssertTrue(register.waitForExistence(timeout: 10))
        if !register.isHittable { app.scrollViews.firstMatch.swipeUp() }
        register.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Create"].isHittable)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Landscape registration with accessibility text size"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Cancel"].tap()
    }
    #endif

}
