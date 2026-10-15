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
        try openFirstPage(app, expectingInitialCrop: false)
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
        try openFirstPage(app, expectingInitialCrop: false)
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
        let field = try requireRenameAlertField(app)
        let original = try XCTUnwrap(field.value as? String)
        XCTAssertEqual(original, seedTitle)
        let renamed = "Documento REA renomeado"
        try tap(field, app: app)
        try dismissKeyboardIntroductionIfPresent(app)
        // This synthetic Latin title occupies one line. A center tap can put
        // the caret before REA; explicitly move to the trailing interior first.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count + 1))
        let clearedValue = try XCTUnwrap(field.value as? String)
        // Native UITextField accessibility returns its placeholder when empty.
        // The exact new value assertion below still rejects leftover text.
        XCTAssertTrue(clearedValue.isEmpty || clearedValue == field.placeholderValue,
                      "The complete original title must be removed before renaming.")
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
        let reopened = try requireRenameAlertField(app)
        XCTAssertEqual(reopened.value as? String, renamed)
        capture("document-renamed-reopened", app: app)
        XCTAssertEqual(app.alerts.firstMatch.buttons.count, 2)
        try tap(app.alerts.firstMatch.buttons.element(boundBy: 0), app: app)
    }

    @MainActor
    private func dismissKeyboardIntroductionIfPresent(_ app: XCUIApplication) throws {
        // Actual simulator AX from run 38683538487: the first-run keyboard
        // tutorial owns this container, its explanatory text, and Continue.
        // This is system setup, not a product action or an app-wide Continue tap.
        let introductions = app.otherElements.matching(identifier: "UIContinuousPathIntroductionView")
        let introduction = introductions.firstMatch
        guard introduction.waitForExistence(timeout: 2) else { return }

        let continueButtons = introduction.buttons.matching(NSPredicate(format: "label == %@", "Continue"))
        let continueButton = continueButtons.firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            // One immutable AX snapshot avoids spending a short timeout on a
            // series of remote count/value queries. Do not match a whole paragraph.
            guard let snapshot = try? introduction.snapshot() else { return false }
            let descendants = self.snapshotTree(snapshot)
            let buttons = descendants.filter { $0.elementType == .button && $0.label == "Continue" }
            let hasKeyboardHint = descendants.contains {
                let label = $0.label.lowercased()
                return $0.elementType == .staticText && label.contains("typing") && label.contains("sliding")
            }
            return snapshot.identifier == "UIContinuousPathIntroductionView" && hasKeyboardHint &&
                buttons.count == 1 && buttons[0].isEnabled
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 10) == .completed else {
            capture("failure-keyboard-introduction-guard", app: app)
            record("keyboard-introduction-AX", text: app.debugDescription)
            XCTFail("Keyboard introduction must contain its typing/sliding hint and exactly one enabled Continue button.")
            throw FlowFailure.transition("keyboard introduction guard")
        }

        let tappable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"),
                                                 object: continueButton)
        guard XCTWaiter.wait(for: [tappable], timeout: 10) == .completed else {
            capture("failure-keyboard-continue-not-hittable", app: app)
            record("keyboard-continue-AX", text: app.debugDescription)
            XCTFail("The identified keyboard introduction Continue button did not become hittable.")
            throw FlowFailure.transition("keyboard Continue readiness")
        }

        capture("system-keyboard-introduction-before-dismissal", app: app)
        // XCTest interruption handling can dismiss this transient system view
        // after resolving an element-based tap. Use its observed on-screen
        // frame once, so that event dispatch does not re-resolve a stale button.
        if !introduction.exists { return }
        let frame = continueButton.frame
        guard !frame.isEmpty, app.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) else {
            XCTFail("Keyboard Continue has no usable on-screen frame.")
            throw FlowFailure.transition("keyboard Continue geometry")
        }
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - app.frame.minX, dy: frame.midY - app.frame.minY)).tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                  object: introduction)
        guard XCTWaiter.wait(for: [dismissed], timeout: 5) == .completed else {
            capture("failure-keyboard-introduction-not-dismissed", app: app)
            XCTFail("The keyboard introduction remained after its single Continue tap.")
            throw FlowFailure.transition("keyboard introduction dismissal")
        }
        capture("system-keyboard-introduction-dismissed", app: app)
    }

    private func snapshotTree(_ snapshot: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
        [snapshot] + snapshot.children.flatMap { snapshotTree($0) }
    }

    @MainActor
    private func requireRenameAlertField(_ app: XCUIApplication) throws -> XCUIElement {
        // CI run 38683538487 exposed one native alert TextField with placeholder
        // Nome and the document value, but dropped its SwiftUI identifier.
        // Scope to the alert and reject ambiguity instead of selecting an app-wide field.
        let alert = app.alerts.firstMatch
        guard alert.waitForExistence(timeout: timeout) else {
            capture("failure-rename-alert-missing", app: app)
            XCTFail("Tapping document.rename must open the native rename alert.")
            throw FlowFailure.missingElement("rename alert")
        }
        guard app.alerts.count == 1 else {
            capture("failure-rename-alert-ambiguous", app: app)
            XCTFail("Expected exactly one native alert while renaming.")
            throw FlowFailure.transition("ambiguous rename alert")
        }
        let field = alert.textFields.firstMatch
        guard field.waitForExistence(timeout: timeout) else {
            capture("failure-rename-alert-field-missing", app: app)
            XCTFail("The native rename alert must expose its text field.")
            throw FlowFailure.missingElement("rename alert text field")
        }
        guard alert.textFields.count == 1 else {
            capture("failure-rename-alert-field-ambiguous", app: app)
            XCTFail("Expected exactly one text field in the rename alert.")
            throw FlowFailure.transition("ambiguous rename alert text field")
        }
        return field
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
    private func openFirstPage(_ app: XCUIApplication, expectingInitialCrop: Bool = true) throws {
        try tapFirstDocumentPage(app)
        _ = try require("editor.screen", app: app)
        capture("editor-opened", app: app)

        let process = element("editor.process", app: app)
        let save = element("editor.save", app: app)
        let adjustments = element("editor.adjustments", app: app)
        if !expectingInitialCrop {
            // Reopening persisted metadata may restore processed mode or start
            // in crop again. Require a real entry state, never an arbitrary delay.
            let entry = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                process.exists || (save.exists && adjustments.exists)
            }, object: nil)
            guard XCTWaiter.wait(for: [entry], timeout: timeout) == .completed else {
                capture("failure-editor-entry-state", app: app)
                XCTFail("Reopened editor exposed neither crop nor processed controls.")
                throw FlowFailure.transition("editor entry state")
            }
        }
        if expectingInitialCrop || process.exists {
            let advance = try require("editor.process", app: app)
            _ = try require("editor.detect-borders", app: app)
            _ = try require("editor.rotate-left", app: app)
            _ = try require("editor.rotate-right", app: app)
            XCTAssertFalse(save.exists, "Save belongs to processed mode, not the initial crop toolbar.")
            XCTAssertFalse(adjustments.exists, "Adjustments require completing the crop step first.")
            capture("editor-crop-before-process", app: app)
            try tap(advance, app: app)
            try requireDisappearance(advance, app: app)
        }
        _ = try require("editor.save", app: app)
        _ = try require("editor.adjustments", app: app)
        capture("editor-processed-after-crop", app: app)
    }

    @MainActor
    private func returnToDocument(_ app: XCUIApplication) throws {
        let editor = element("editor.screen", app: app)
        if editor.exists {
            // Leave via the editor's explicit cancellation action. A processed
            // crop may be dirty even after the adjustment draft was cancelled.
            try tap("editor.cancel", app: app)
            let discardInAlert = app.alerts.buttons.matching(
                NSPredicate(format: "label == %@", "Descartar e sair")).firstMatch
            let discardInSheet = app.sheets.buttons.matching(
                NSPredicate(format: "label == %@", "Descartar e sair")).firstMatch
            let exitOrConfirmation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !editor.exists || discardInAlert.exists || discardInSheet.exists
            }, object: nil)
            guard XCTWaiter.wait(for: [exitOrConfirmation], timeout: timeout) == .completed else {
                capture("failure-editor-cancel-transition", app: app)
                record("editor-cancel-AX", text: app.debugDescription)
                XCTFail("Editor cancellation neither dismissed the editor nor presented its discard confirmation.")
                throw FlowFailure.transition("editor.cancel")
            }
            // This destructive confirmation is confined to the synthetic
            // document and to a modal reached by the explicit cancel action.
            if discardInAlert.exists {
                capture("editor-discard-confirmation", app: app)
                try tap(discardInAlert, app: app)
            } else if discardInSheet.exists {
                capture("editor-discard-confirmation", app: app)
                try tap(discardInSheet, app: app)
            }
        }
        try requireDisappearance(editor, app: app)
        _ = try require("document.screen", app: app)
        XCTAssertFalse(app.alerts.firstMatch.exists, "No modal may cover the document after editor exit.")
        XCTAssertFalse(app.sheets.firstMatch.exists, "The discard sheet must be dismissed before reopening a page.")
        try assertTwoPages(app)
    }

    @MainActor
    private func tapFirstDocumentPage(_ app: XCUIApplication) throws {
        // The observed native List is a CollectionView identified as
        // document.screen. Scope to that list instead of searching all app buttons.
        // Run 38685680588 stalled while resolving the FIRST page query, before
        // any editor action. Reacquire once after a read-only readiness timeout;
        // never retry a tap or dismiss an unrelated alert to make the test pass.
        for attempt in 1...2 {
            let list = app.collectionViews.matching(identifier: "document.screen").firstMatch
            let page = list.buttons.matching(identifier: "document.page").firstMatch
            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"),
                object: page)
            if XCTWaiter.wait(for: [ready], timeout: timeout) == .completed {
                page.tap()
                return
            }
            capture("document-page-readiness-attempt-\(attempt)", app: app)
            record("document-page-readiness-AX-\(attempt)", text: app.debugDescription)
            guard element("document.screen", app: app).exists,
                  !element("editor.screen", app: app).exists,
                  !app.alerts.firstMatch.exists, !app.sheets.firstMatch.exists else { break }

            // Authorized fallback for a visible, enabled row whose AX readiness
            // timed out. Derive coordinates from a fresh snapshot, never a
            // hard-coded screenshot location, and issue at most one real tap.
            if let snapshot = try? page.snapshot(), snapshot.elementType == .button,
               snapshot.identifier == "document.page", snapshot.isEnabled {
                let frame = snapshot.frame
                let bounds = app.frame
                if !frame.isEmpty && !frame.isNull && !frame.isInfinite && bounds.contains(frame) {
                    record("document-page-coordinate-fallback",
                           text: "AX readiness timed out; enabled document.page frame=\(frame), app=\(bounds). One center tap; editor transition is required.")
                    app.coordinate(withNormalizedOffset: .zero)
                        .withOffset(CGVector(dx: frame.midX - bounds.minX, dy: frame.midY - bounds.minY)).tap()
                    _ = try require("editor.screen", app: app)
                    return
                }
            }
            guard attempt == 1 else { break }
        }
        XCTFail("The first document.page did not become enabled and hittable after bounded query reacquisition.")
        throw FlowFailure.transition("document.page readiness")
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
            record("failure-control-full-AX", text: app.debugDescription)
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
            record("failure-transition-full-AX", text: app.debugDescription)
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
        // Saving intentionally dismisses the editor. Never read enabled/hittable
        // from editor.save after the tap: it can disappear between AX requests.
        try requireDisappearance(element("editor.screen", app: app), app: app)
        _ = try require("document.screen", app: app)
        XCTAssertFalse(app.alerts.firstMatch.exists, "Saving must not leave an error alert.")
        try assertTwoPages(app)
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
