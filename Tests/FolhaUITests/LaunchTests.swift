import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testLibraryOpensWithCaptureAndImport() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Folha"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Digitalizar"].exists)
        XCTAssertTrue(app.buttons["Importar"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Folha-library-simulator"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
