import XCTest

final class LaunchTests: XCTestCase {
    private let timeout: TimeInterval = 45
    private let seedTitle = "Documento de teste REA"

    private enum FlowFailure: Error {
        case missingElement(String)
        case unavailableValue(String)
        case transition(String)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEmptyIsolatedLibrary() throws {
        let app = try launchFixture(seeded: false)
        defer { app.terminate() }
        XCTAssertEqual(app.buttons.matching(identifier: "library.document").count, 0)
        capture("library-empty", app: app)
    }

    @MainActor
    func testSeededLibraryOpensDocumentAndPage() throws {
        let app = try launchFixture(seeded: true)
        defer { app.terminate() }
        try openSeededDocument(app)
        capture("document-two-synthetic-pages", app: app)
        try openFirstPage(app)
        _ = try require("editor.save", app: app)
        capture("editor-synthetic-page", app: app)
    }

    @MainActor
    func testCancelAdjustmentsRestoresValuesAfterReopeningPage() throws {
        let app = try launchFixture(seeded: true)
        defer { app.terminate() }
        try openSeededDocument(app)
        try openFirstPage(app)
        try tap("editor.adjustments", app: app)
        _ = try require("editor.cancel-adjustments", app: app)
        _ = try require("editor.adjustment.slider", app: app)
        let before = try sliderValues(app)
        capture("adjustments-before-cancel", app: app)
        try changeFirstSlider(app)
        XCTAssertNotEqual(try sliderValues(app), before)
        capture("adjustments-draft-to-discard", app: app)
        try tap("editor.cancel-adjustments", app: app)
        try requireDisappearance(element("editor.cancel-adjustments", app: app), app: app)

        // Check reopening the panel, then recreate the editor from the page.
        try tap("editor.adjustments", app: app)
        XCTAssertEqual(try sliderValues(app), before)
        try tap("editor.cancel-adjustments", app: app)
        try returnToDocument(app)
        try openFirstPage(app)
        try tap("editor.adjustments", app: app)
        XCTAssertEqual(try sliderValues(app), before, "Cancelled values must not survive reopening the page.")
        record("cancel-values", text: "Before: \(before)\nReopened: \(try sliderValues(app))")
        capture("adjustments-cancel-reopened-unchanged", app: app)
        try tap("editor.cancel-adjustments", app: app)
    }

    @MainActor
    func testConfirmSaveAndReopenPageRetainsChangedAdjustment() throws {
        let app = try launchFixture(seeded: true)
        defer { app.terminate() }
        try openSeededDocument(app)
        try openFirstPage(app)
        try tap("editor.adjustments", app: app)
        _ = try require("editor.confirm-adjustments", app: app)
        _ = try require("editor.adjustment.slider", app: app)
        let before = try sliderValues(app)
        try changeFirstSlider(app)
        let changed = try sliderValues(app)
        XCTAssertNotEqual(changed, before)
        capture("adjustments-draft-to-commit", app: app)
        try tap("editor.confirm-adjustments", app: app)
        try requireDisappearance(element("editor.confirm-adjustments", app: app), app: app)
        try tap("editor.save", app: app)
        try waitForSaveToSettle(app)
        capture("editor-after-save", app: app)
        try returnToDocument(app)
        try openFirstPage(app)
        try tap("editor.adjustments", app: app)
        XCTAssertEqual(try sliderValues(app), changed, "The saved edit must survive recreating the page editor.")
        record("saved-values", text: "Before: \(before)\nCommitted: \(changed)\nReopened: \(try sliderValues(app))")
        capture("editor-reopened-saved-values", app: app)
        try tap("editor.cancel-adjustments", app: app)
        // Do not relaunch here: --uitesting creates a fresh namespace per launch.
        // This proves page reopening in one session, not process-restart durability.
    }

    @MainActor
    func testPDFPreviewOpensFromTwoPageSyntheticDocument() throws {
        let app = try launchFixture(seeded: true)
        defer { app.terminate() }
        try openSeededDocument(app)
        let previewButton = try require("document.previewPDF", app: app)
        // The export section may be below the two page rows on smaller phones.
        for _ in 0..<3 {
            if previewButton.isHittable { break }
            app.swipeUp()
        }
        try tap(previewButton, app: app)
        let preview = try require("pdf.preview", app: app)
        // This title is part of the explicitly agreed UI contract, not a title
        // borrowed from the original reference application.
        XCTAssertTrue(app.navigationBars["PDF - 2 paginas"].waitForExistence(timeout: timeout),
                      "The PDF preview must report the two pages in the synthetic fixture.")
        capture("pdf-preview-two-page-fixture-top", app: app)
        preview.swipeUp()
        capture("pdf-preview-two-page-fixture-scrolled", app: app)
        record("pdf-count-observability", text:
            "The source document contains exactly two synthetic pages; pdf.preview opened " +
            "with the agreed title PDF - 2 paginas. This asserts the UI-reported page count, " +
            "not an independent parse of the exported PDF binary.")
    }

    @MainActor
    func testRenameDocumentIsVisibleInLibraryAndAfterReopening() throws {
        let app = try launchFixture(seeded: true)
        defer { app.terminate() }
        try openSeededDocument(app)
        try tap("document.rename", app: app)
        let field = try require("document.renameField", app: app)
        let original = try XCTUnwrap(field.value as? String)
        XCTAssertEqual(original, seedTitle)
        let renamed = "Documento REA renomeado"
        try tap(field, app: app)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count))
        field.typeText(renamed)
        XCTAssertEqual(field.value as? String, renamed)
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: timeout))
        // Salvar is the explicitly agreed alert action; scope it to this alert
        // rather than accidentally targeting the page editor's save control.
        try tap(alert.buttons["Salvar"], app: app)
        try requireDisappearance(alert, app: app)
        try navigateBack(to: "library.screen", app: app)
        let row = app.buttons.matching(identifier: "library.document").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: timeout))
        XCTAssertEqual(app.buttons.matching(identifier: "library.document").count, 1)
        XCTAssertTrue(row.label.contains(renamed) || row.staticTexts[renamed].exists)
        capture("library-document-renamed", app: app)
        try tap(row, app: app)
        _ = try require("document.screen", app: app)
        try assertTwoPages(app)
        try tap("document.rename", app: app)
        let reopened = try require("document.renameField", app: app)
        XCTAssertEqual(reopened.value as? String, renamed)
        capture("document-renamed-reopened", app: app)
        XCTAssertEqual(app.alerts.firstMatch.buttons.count, 2)
        try tap(app.alerts.firstMatch.buttons.element(boundBy: 0), app: app)
    }

    @MainActor
    private func launchFixture(seeded: Bool) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        if seeded { app.launchArguments.append("--seed-test-document") }
        // The application, not this runner, owns an isolated temporary namespace.
        // Never launch without --uitesting or import from Photos/camera/network.
        app.launch()
        _ = try require("library.screen", app: app)
        capture(seeded ? "library-seeded-launch" : "library-empty-launch", app: app)
        record("fixture", text: "Arguments: \(app.launchArguments)\nSynthetic data only; fresh namespace expected per launch.")
        return app
    }

    @MainActor
    private func openSeededDocument(_ app: XCUIApplication) throws {
        let rows = app.buttons.matching(identifier: "library.document")
        let first = rows.firstMatch
        guard first.waitForExistence(timeout: timeout) else {
            capture("failure-seed-not-ready", app: app)
            XCTFail("Synthetic document did not become available within \(timeout) seconds.")
            throw FlowFailure.missingElement("library.document")
        }
        XCTAssertEqual(rows.count, 1, "The temporary fixture must not include real documents.")
        XCTAssertTrue(first.label.contains(seedTitle) || first.staticTexts[seedTitle].exists)
        try tap(first, app: app)
        _ = try require("document.screen", app: app)
        try assertTwoPages(app)
    }

    @MainActor
    private func assertTwoPages(_ app: XCUIApplication) throws {
        let pages = app.buttons.matching(identifier: "document.page")
        guard pages.firstMatch.waitForExistence(timeout: timeout) else {
            capture("failure-pages-not-ready", app: app)
            XCTFail("The synthetic document has no accessible page rows.")
            throw FlowFailure.missingElement("document.page")
        }
        XCTAssertEqual(pages.count, 2, "The fixture must retain exactly two synthetic pages.")
    }

    @MainActor
    private func openFirstPage(_ app: XCUIApplication) throws {
        try tap(app.buttons.matching(identifier: "document.page").firstMatch, app: app)
        _ = try require("editor.screen", app: app)
        capture("editor-opened", app: app)
    }

    @MainActor
    private func returnToDocument(_ app: XCUIApplication) throws {
        if element("editor.screen", app: app).exists {
            try navigateBack(to: "document.screen", app: app)
        } else {
            _ = try require("document.screen", app: app)
        }
        try assertTwoPages(app)
    }

    @MainActor
    private func navigateBack(to identifier: String, app: XCUIApplication) throws {
        // Native NavigationStack back is the first navigation-bar button in the
        // inspected app. No original-product title is used as a selector.
        let back = app.navigationBars.firstMatch.buttons.firstMatch
        try tap(back, app: app)
        _ = try require(identifier, app: app)
    }

    @MainActor
    private func element(_ identifier: String, app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func require(_ identifier: String, app: XCUIApplication) throws -> XCUIElement {
        let result = element(identifier, app: app)
        guard result.waitForExistence(timeout: timeout) else {
            capture("failure-missing-\(identifier)", app: app)
            XCTFail("Missing accessibility identifier: \(identifier)")
            throw FlowFailure.missingElement(identifier)
        }
        return result
    }

    @MainActor
    private func tap(_ identifier: String, app: XCUIApplication) throws {
        try tap(require(identifier, app: app), app: app)
    }

    @MainActor
    private func tap(_ target: XCUIElement, app: XCUIApplication) throws {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"),
            object: target)
        guard XCTWaiter.wait(for: [ready], timeout: timeout) == .completed else {
            capture("failure-control-not-interactable", app: app)
            XCTFail("Control not interactable: \(target.identifier)")
            throw FlowFailure.missingElement(target.identifier)
        }
        target.tap()
    }

    @MainActor
    private func requireDisappearance(_ target: XCUIElement, app: XCUIApplication) throws {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: target)
        guard XCTWaiter.wait(for: [gone], timeout: timeout) == .completed else {
            capture("failure-transition", app: app)
            XCTFail("Control did not disappear after completing its flow: \(target.identifier)")
            throw FlowFailure.transition(target.identifier)
        }
    }

    @MainActor
    private func sliderValues(_ app: XCUIApplication) throws -> [String] {
        // The editor uses one slider for three explicitly identified controls.
        // Snapshot all controls rather than accidentally checking only contrast.
        var values: [String] = []
        for control in ["contrast", "brightness", "detail"] {
            try tap("editor.adjustment.\(control)", app: app)
            let slider = try require("editor.adjustment.slider", app: app)
            guard let value = slider.value as? String, !value.isEmpty else {
                XCTFail("Slider has no readable value: \(slider.identifier)")
                throw FlowFailure.unavailableValue(slider.identifier)
            }
            values.append("\(control):\(value)")
        }
        try tap("editor.adjustment.contrast", app: app)
        return values
    }

    @MainActor
    private func changeFirstSlider(_ app: XCUIApplication) throws {
        try tap("editor.adjustment.contrast", app: app)
        let slider = try require("editor.adjustment.slider", app: app)
        let before = try XCTUnwrap(slider.value as? String)
        slider.adjust(toNormalizedSliderPosition: 0.8)
        if slider.value as? String == before {
            slider.adjust(toNormalizedSliderPosition: 0.2)
        }
        XCTAssertNotEqual(slider.value as? String, before, "The fixture must actually change before cancel/save is tested.")
    }

    @MainActor
    private func waitForSaveToSettle(_ app: XCUIApplication) throws {
        let editor = element("editor.screen", app: app)
        let document = element("document.screen", app: app)
        let save = element("editor.save", app: app)
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (!editor.exists && document.exists) || (save.exists && save.isEnabled && save.isHittable)
        }, object: nil)
        guard XCTWaiter.wait(for: [finished], timeout: timeout) == .completed else {
            capture("failure-save-timeout", app: app)
            XCTFail("The editor did not finish saving within \(timeout) seconds.")
            throw FlowFailure.transition("editor.save")
        }
        XCTAssertFalse(app.alerts.firstMatch.exists, "Saving must not leave an error alert.")
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "REA-\(name)-\(Int(app.frame.width))x\(Int(app.frame.height))"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func record(_ name: String, text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "REA-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
