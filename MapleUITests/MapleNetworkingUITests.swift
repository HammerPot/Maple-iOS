import XCTest

final class MapleNetworkingUITests: XCTestCase {
    @MainActor
    func testAccountFormAndSocialSettings() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["Account"].tap()
        XCTAssertTrue(app.textFields["Username"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.secureTextFields["Password"].exists)
        XCTAssertTrue(app.buttons["Register"].exists)
        app.tabBars.buttons["Settings"].tap()
        let connection = app.switches["Enable social connection"]
        XCTAssertTrue(connection.waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Share playback with Discord"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Social connection settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testLiveLoginRestoresSessionAndLogsOut() throws {
        let url = Bundle(for: Self.self).url(forResource: "MapleLiveTestCredentials", withExtension: "json")
        try XCTSkipUnless(url != nil, "Provide an ignored MapleLiveTestCredentials.json resource to opt into live API testing.")
        let credentials = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(url))) as? [String: String])
        let username = try XCTUnwrap(credentials["username"])
        let password = try XCTUnwrap(credentials["password"])
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["Account"].tap()
        let usernameField = app.textFields["Username"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 10))
        usernameField.tap()
        usernameField.typeText(username)
        let passwordField = app.secureTextFields["Password"]
        passwordField.tap()
        passwordField.typeText(password)
        app.buttons["Login"].tap()
        XCTAssertTrue(app.buttons["Manage Account"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons[username].exists)
        app.terminate()
        app.launch()
        app.tabBars.buttons["Account"].tap()
        XCTAssertTrue(app.buttons["Manage Account"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons[username].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Authenticated Maple account after relaunch"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let logout = app.buttons["Logout"]
        if !logout.isHittable { app.swipeUp() }
        logout.tap()
        app.alerts.buttons["Logout"].tap()
        XCTAssertTrue(usernameField.waitForExistence(timeout: 15))
    }
}
