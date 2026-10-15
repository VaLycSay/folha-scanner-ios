import XCTest
@testable import Folha

// Pure policy tests, not a claim of UI execution or original-app parity.
final class EditorPresentationTests: XCTestCase {
    func testBackFromAdjustmentsCancelsOnlyTheUncommittedStage() {
        for returnsToProcessed in [false, true] {
            XCTAssertEqual(EditorPresentation.backAction(stage: .adjustments,
                cropReturnsToProcessed: returnsToProcessed), .cancelAdjustments)
        }
    }

    func testInitialCropCanExitButReprocessingCropReturnsToPreview() {
        XCTAssertEqual(EditorPresentation.backAction(stage: .crop,
            cropReturnsToProcessed: false), .leaveEditor)
        XCTAssertEqual(EditorPresentation.backAction(stage: .crop,
            cropReturnsToProcessed: true), .cancelCrop)
    }

    func testProcessedPageRetainsTheEditorExitAndDiscardGate() {
        for returnsToProcessed in [false, true] {
            XCTAssertEqual(EditorPresentation.backAction(stage: .processed,
                cropReturnsToProcessed: returnsToProcessed), .leaveEditor)
        }
    }

    func testMagicColorUsesTheRecoveredPortugueseLabelWithoutChangingModeIDs() {
        XCTAssertEqual(EditorPresentation.filterTitle(.clean), "Cor M\u{00E1}gica")
        XCTAssertEqual(EditorFilterCatalog.nativeModeID(.clean), 2)
        for filter in PageFilter.allCases where filter != .clean {
            XCTAssertEqual(EditorPresentation.filterTitle(filter), EditorFilterCatalog.title(filter))
        }
    }
}
