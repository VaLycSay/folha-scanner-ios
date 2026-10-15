import XCTest

final class ScannerShellTests: XCTestCase {
    @MainActor
    private func launch(seeded: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"] + (seeded ? ["--seed-test-document"] : [])
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["library.screen"].waitForExistence(timeout: 40))
        return app
    }
    @MainActor
    func testHomeHasToolsSearchAndCamera() {
        let app = launch(seeded: false)
        defer { app.terminate() }
        let search = app.textFields["library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 20))
        if !search.exists {
            let state = XCTAttachment(string: app.debugDescription)
            state.name = "REA-v04-search-accessibility"; state.lifetime = .keepAlways; add(state)
        }
        XCTAssertTrue(app.buttons["library.scan"].exists)
        for label in ["Digitalizar", "Importar fotos", "Importar arquivos", "PDF", "Extrair texto", "Assinatura", "Filtros", "Todas"] {
            XCTAssertTrue(app.buttons["library.tool.\(label)"].exists, label)
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "REA-v04-home-tools"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor
    func testFilesToolsAndProfileReturnToHome() {
        let app = launch()
        defer { app.terminate() }
        for name in ["Arquivos", "Ferramentas", "Eu", "Inicio"] {
            let button = app.buttons["library.tab.\(name)"]
            XCTAssertTrue(button.waitForExistence(timeout: 40)); button.tap()
        }
        XCTAssertTrue(app.buttons["library.document"].firstMatch.waitForExistence(timeout: 40))
    }
    @MainActor
    func testExportPanelOffersRealFormats() {
        let app = launch()
        defer { app.terminate() }
        let row = app.buttons["library.document"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 40)); row.tap()
        let share = app.buttons["document.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 40)); share.tap()
        XCTAssertTrue(app.descendants(matching: .any)["export.screen"].waitForExistence(timeout: 20))
        for format in ["PDF", "JPG", "TXT"] { XCTAssertTrue(app.buttons["export.\(format)"].exists) }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "REA-v04-export-panel"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor
    func testFilesSelectionSurvivesLayoutChangeWithoutOpeningDocument() {
        let app = launch()
        defer { app.terminate() }
        let row = app.buttons["library.document"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 40))
        app.buttons["library.tab.Arquivos"].tap()
        let layout = app.buttons["library.layout"]
        XCTAssertTrue(layout.waitForExistence(timeout: 20))
        app.buttons["library.selectAll"].tap()
        XCTAssertEqual(app.staticTexts["library.selection.count"].label, "1 selecionados")
        layout.tap()
        let selected = app.buttons["library.select"].firstMatch
        XCTAssertEqual(selected.value as? String, "Selecionado")
        selected.tap()
        XCTAssertEqual(app.staticTexts["library.selection.count"].label, "0 selecionados")
        XCTAssertFalse(app.buttons["library.selection.share"].isEnabled)
        app.buttons["library.document"].firstMatch.tap()
        XCTAssertEqual(app.staticTexts["library.selection.count"].label, "1 selecionados")
        app.buttons["library.selection.cancel"].tap()
        app.buttons["library.document"].firstMatch.tap()
        XCTAssertTrue(app.buttons["document.share"].waitForExistence(timeout: 20))
    }

    @MainActor
    func testRecentShareOpensActualExportPanel() {
        let app = launch()
        defer { app.terminate() }
        let share = app.buttons["library.recent.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 40))
        share.tap()
        for format in ["PDF", "JPG", "TXT"] {
            XCTAssertTrue(app.buttons["export.\(format)"].waitForExistence(timeout: 20))
        }
    }
}
