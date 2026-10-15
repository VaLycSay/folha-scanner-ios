import XCTest

final class NuvioSmokeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.nuvio.media")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 45))
        XCTAssertTrue(app.buttons.firstMatch.waitForExistence(timeout: 30) ||
                      app.staticTexts.firstMatch.waitForExistence(timeout: 10),
                      "The app must show accessible content, not just a blank process")
    }

    override func tearDownWithError() throws { app.terminate() }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLaunchShowsVisibleContent() { capture("01-launch") }

    func testForegroundRoundTrip() {
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(app.buttons.firstMatch.exists || app.staticTexts.firstMatch.exists)
        capture("02-foreground")
    }

    func testLandscapeKeepsAppResponsive() {
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(app.buttons.firstMatch.exists || app.staticTexts.firstMatch.exists)
        capture("03-landscape")
    }
}
