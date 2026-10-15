import XCTest
import UIKit
@testable import Folha

// Tests of independently reconstructed contracts, not execution of the reference
// application, its private APIs, camera, artwork, or image-processing engine.
final class RecoveredFlowTests: XCTestCase {
    private typealias Toolbar = RecoveredEditorToolbarContract
    private typealias Scan = NativeScanConfiguration

    func testOperationIDsAreNativeIDsRatherThanToolbarPositions() {
        XCTAssertEqual(Toolbar.Operation.allCases.map(\.rawValue), [
            5, 17, 18, 19, 20, 21, 22, 23, 50, 51, 52, 53,
            73, 74, 77, 78, 79, 80, 81, 82, 83
        ])
        XCTAssertNil(Toolbar.Operation(rawValue: 0))
        XCTAssertNil(Toolbar.Operation(rawValue: 24))
        XCTAssertEqual(Toolbar.Operation(rawValue: 53), .fineTunePage)
        XCTAssertNotEqual(Toolbar.Operation.fineTune, .fineTunePage)
        XCTAssertNotEqual(Toolbar.Operation.smudgePage, .smudgeEditor)
    }

    func testEveryOperationHasADescriptorAndOnlyCancelHasNoTitle() {
        XCTAssertEqual(Set(Toolbar.descriptors.keys), Set(Toolbar.Operation.allCases))
        for operation in Toolbar.Operation.allCases {
            guard let descriptor = Toolbar.descriptors[operation] else {
                XCTFail("Missing descriptor for operation \(operation.rawValue)")
                continue
            }
            XCTAssertFalse(descriptor.nativeAction.isEmpty)
            XCTAssertNotNil(descriptor.referenceImageName)
            if operation == .cancelAdjustment {
                XCTAssertNil(descriptor.localizedTitleKey)
            } else {
                XCTAssertNotNil(descriptor.localizedTitleKey)
            }
        }
        XCTAssertEqual(Toolbar.descriptors[.detectBorders]?.selectedTitleKey, "cs_512_title_auto")
    }

    func testDefaultToolbarSequencesAndSeparateConfirmation() {
        let cases: [(Toolbar.Layout, [Int], Int?)] = [
            (.crop, [17, 18, 19, 20], nil),
            (.legacyAfterProcess, [18, 21, 22, 23], nil),
            (.processed, [18, 77, 73, 79, 78, 21], 23),
            (.adjustments, [80, 83, 82, 81, 23], nil),
            (.pageList, [50, 52, 5, 53, 51], nil)
        ]
        for (layout, ids, separateDone) in cases {
            let spec = Toolbar.layout(layout)
            XCTAssertEqual(spec.items.map(\.rawValue), ids)
            XCTAssertEqual(spec.separateDone?.rawValue, separateDone)
            XCTAssertEqual(Set(spec.items).count, spec.items.count)
            if let done = spec.separateDone { XCTAssertFalse(spec.items.contains(done)) }
        }
    }

    func testOnlyReferenceModeTenInsertsCaptureBetweenRotations() {
        for mode in [-1, 0, 9, 10, 11] {
            let expected = mode == 10 ? [17, 18, 74, 19, 20] : [17, 18, 19, 20]
            XCTAssertEqual(Toolbar.layout(.crop, referenceMode: mode).items.map(\.rawValue), expected)
        }
    }

    func testOnlyLegacyViewTypeOneOmitsOCR() {
        for viewType in [-1, 0, 1, 2] {
            let expected = viewType == 1 ? [18, 22, 23] : [18, 21, 22, 23]
            XCTAssertEqual(Toolbar.layout(.legacyAfterProcess, viewType: viewType).items.map(\.rawValue), expected)
            XCTAssertEqual(Toolbar.layout(.processed, viewType: viewType).items.map(\.rawValue), [18, 77, 73, 79, 78, 21])
        }
    }

    func testStatelessDispatchUsesOperationIdentityNotPosition() {
        let cases: [(Toolbar.Operation, Toolbar.Intent)] = [
            (.deletePage, .deletePage), (.detectBorders, .detectBorders),
            (.rotateRight, .rotateRight), (.processCrop, .clearOCRAndProcessCrop),
            (.recognizeText, .recognizeText), (.fineTune, .showAdjustments),
            (.fineTunePage, .showAdjustments), (.retake, .retakePhoto),
            (.continueCapture, .continueCapture), (.smudgePage, .smudgePage),
            (.signature, .showSignature), (.addCapture, .addCapture),
            (.textWatermark, .showTextWatermark), (.annotation, .enterInkNote(mode: 0)),
            (.smudgeEditor, .enterInkNote(mode: 1)), (.cancelAdjustment, .cancelAdjustments),
            (.detail, .selectAdjustment(.detail)), (.brightness, .selectAdjustment(.brightness)),
            (.contrast, .selectAdjustment(.contrast))
        ]
        for status in [0, 2, 3] {
            for (operation, expected) in cases {
                assertIntent(plan(operation, status: status).intent, equals: expected)
            }
        }
    }

    func testDoneCommitsAdjustmentsOnlyInStatusThreeAndOtherwiseSaves() {
        for status in [-1, 0, 1, 2, 3, 4] {
            assertIntent(plan(.done, status: status).intent,
                         equals: status == 3 ? .confirmAdjustments : .savePage)
            assertIntent(plan(.cancelAdjustment, status: status).intent, equals: .cancelAdjustments)
        }
    }

    func testCropAdjustCancelAdjustCommitAndSaveIntentSequence() {
        // Status is supplied by the caller: this asserts a dispatch sequence,
        // not a state machine or pixel rollback implemented by this contract.
        let sequence: [(Toolbar.Operation, Int, Toolbar.Intent)] = [
            (.processCrop, 0, .clearOCRAndProcessCrop),
            (.fineTune, 2, .showAdjustments),
            (.brightness, 3, .selectAdjustment(.brightness)),
            (.cancelAdjustment, 3, .cancelAdjustments),
            (.fineTunePage, 2, .showAdjustments),
            (.contrast, 3, .selectAdjustment(.contrast)),
            (.detail, 3, .selectAdjustment(.detail)),
            (.done, 3, .confirmAdjustments),
            (.done, 2, .savePage)
        ]
        for (operation, status, expected) in sequence {
            assertIntent(plan(operation, status: status).intent, equals: expected)
        }
    }

    func testLeftRotationDistinguishesCropProcessedAndUnsupportedStatuses() {
        for containsOCR in [false, true] {
            assertIntent(plan(.rotateLeft, status: 0, ocr: containsOCR).intent, equals: .rotateLeft)
            assertIntent(plan(.rotateLeft, status: 2, ocr: containsOCR).intent,
                         equals: .rotateProcessedPage(requiresOCRConfirmation: containsOCR))
            for status in [-1, 1, 3, 4] {
                assertIntent(plan(.rotateLeft, status: status, ocr: containsOCR).intent, equals: .noAction)
            }
            assertIntent(plan(.rotateRight, status: 2, ocr: containsOCR).intent, equals: .rotateRight)
        }
    }

    func testZoomResetOnlyAppliesToProcessedStatusAndExemptsExactlyIDs18And22() {
        for operation in Toolbar.Operation.allCases {
            for status in [-1, 0, 1, 2, 3, 4] {
                for zoom in [0.5, 1.0, 2.0] {
                    let expected = status == 2 && zoom != 1 && ![18, 22].contains(operation.rawValue)
                    XCTAssertEqual(plan(operation, status: status, zoom: zoom).resetZoomFirst, expected,
                                   "operation=\(operation.rawValue), status=\(status), zoom=\(zoom)")
                }
            }
        }
        XCTAssertFalse(plan(.fineTune, status: 2, zoom: 2).resetZoomFirst)
        XCTAssertTrue(plan(.fineTunePage, status: 2, zoom: 2).resetZoomFirst)
    }

    func testSixNativeFiltersHaveDisplayOrderDifferentFromRawIDs() {
        let filters = Scan.filters(removeShadowEnabled: false)
        XCTAssertEqual(filters.map(\.rawValue), [0, 1, 2, 5, 3, 4])
        XCTAssertEqual(filters.map(\.titleKey), ["Original", "Lighten", "Magic Color", "B&W", "B&W 2", "Grayscale"])
        XCTAssertEqual(filters.count, 6)
        XCTAssertEqual(filters[3], .blackAndWhite)
        XCTAssertEqual(Scan.Filter(rawValue: 3), .blackAndWhite2)
    }

    func testShadowIsPrependedWithoutRenumberingTheSixBaseFilters() {
        let filters = Scan.filters(removeShadowEnabled: true)
        XCTAssertEqual(filters.map(\.rawValue), [6, 0, 1, 2, 5, 3, 4])
        XCTAssertEqual(Array(filters.dropFirst()), Scan.filters(removeShadowEnabled: false))
        XCTAssertEqual(Set(filters), Set(Scan.Filter.allCases))
        XCTAssertEqual(filters.first?.titleKey, "no_cs_520c_remove_shadow")
    }

    func testSingleImageInitialFilterRestoresRawIDNotDisplayIndex() {
        for shadow in [false, true] {
            let available = Scan.filters(removeShadowEnabled: shadow)
            for filter in available {
                XCTAssertEqual(Scan.initialFilter(previousRawValue: filter.rawValue,
                                                  supportsMultipleImages: false, available: available), filter)
            }
            XCTAssertEqual(Scan.initialFilter(previousRawValue: nil,
                                              supportsMultipleImages: false, available: available), .original)
        }
    }

    func testMultipleImagesPreferMagicColorOverPreviousChoiceIncludingShadow() {
        let available = Scan.filters(removeShadowEnabled: true)
        for previous: Int? in [nil, -1, 0, 3, 5, 6, 99] {
            XCTAssertEqual(Scan.initialFilter(previousRawValue: previous,
                                              supportsMultipleImages: true, available: available), .magicColor)
        }
    }

    func testInitialFilterFallsBackToFirstAvailableAndEmptyStaysEmpty() {
        for multiple in [false, true] {
            XCTAssertNil(Scan.initialFilter(previousRawValue: 2, supportsMultipleImages: multiple, available: []))
            XCTAssertEqual(Scan.initialFilter(previousRawValue: 999, supportsMultipleImages: multiple,
                                              available: [.grayscale, .original]), .grayscale)
        }
        XCTAssertEqual(Scan.initialFilter(previousRawValue: 6, supportsMultipleImages: false,
                                          available: Scan.filters(removeShadowEnabled: false)), .original)
        XCTAssertEqual(Scan.initialFilter(previousRawValue: -1, supportsMultipleImages: false,
                                          available: Scan.filters(removeShadowEnabled: true)), .removeShadow)
    }

    func testCameraIDsAreNotDisplayPositionsOrPickerModeIDs() {
        XCTAssertEqual(Scan.CameraMode.allCases.map(\.rawValue), Array(0...11))
        let modes = Scan.cameraModes(.init(supportsIdentityPhoto: false, electronicEvidenceEnabled: true))
        XCTAssertEqual(modes.first, .spreadsheetRecognition)
        XCTAssertEqual(modes.first?.rawValue, 9)
        XCTAssertEqual(Scan.CameraMode.signature.rawValue, 6)
        XCTAssertEqual(Scan.CameraMode.spreadsheetRecognition.nativeAction, "excelModeButtonDidClicked:")
        XCTAssertEqual(Scan.CameraMode.signature.nativeAction, "signatureModeButtonDidClicked:")
        XCTAssertEqual(Scan.CameraMode.qrCode.nativeAction, "qrCodeModeButtonDidClicked:")
        XCTAssertTrue(Scan.CameraMode.allCases.allSatisfy { !$0.nativeAction.isEmpty })
    }

    func testCameraDefaultSequencesForBothFeatureFlags() {
        let cases: [(Bool, Bool, [Int])] = [
            (false, true, [9, 7, 1, 2, 3, 5, 4, 11, 0, 8]),
            (true, true, [9, 10, 7, 1, 2, 3, 5, 4, 11, 0, 8]),
            (false, false, [0, 9, 7, 1, 2, 3, 5, 4]),
            (true, false, [0, 9, 10, 7, 1, 2, 3, 5, 4])
        ]
        for (identityPhoto, evidence, expected) in cases {
            let modes = Scan.cameraModes(.init(supportsIdentityPhoto: identityPhoto,
                                               electronicEvidenceEnabled: evidence))
            XCTAssertEqual(modes.map(\.rawValue), expected)
            XCTAssertEqual(Set(modes).count, modes.count)
        }
    }

    func testSignaturePickerOverridesFeatureBasedCameraModes() {
        for identityPhoto in [false, true] {
            for evidence in [false, true] {
                XCTAssertEqual(Scan.cameraModes(.init(supportsIdentityPhoto: identityPhoto,
                                                       electronicEvidenceEnabled: evidence,
                                                       signaturePicker: true)), [.signature])
            }
        }
    }

    func testRestrictionOverridesSignaturePreservesOrderAndAppendsMissingCurrentMode() {
        let options = Scan.CameraOptions(supportsIdentityPhoto: true, electronicEvidenceEnabled: true,
                                         signaturePicker: true, restrictedModes: [.multiplePages, .singlePage],
                                         currentRestrictedMode: .textRecognition)
        XCTAssertEqual(Scan.cameraModes(options), [.multiplePages, .singlePage, .textRecognition])
        var alreadyPresent = options
        alreadyPresent.currentRestrictedMode = .multiplePages
        XCTAssertEqual(Scan.cameraModes(alreadyPresent), [.multiplePages, .singlePage])
    }

    func testNilRestrictionDiffersFromEmptyAndCurrentModeOnlyAffectsRestrictions() {
        var options = Scan.CameraOptions(supportsIdentityPhoto: false, electronicEvidenceEnabled: false,
                                         currentRestrictedMode: .signature)
        XCTAssertEqual(Scan.cameraModes(options).map(\.rawValue), [0, 9, 7, 1, 2, 3, 5, 4])
        options.restrictedModes = []
        options.currentRestrictedMode = nil
        XCTAssertEqual(Scan.cameraModes(options), [])
        options.currentRestrictedMode = .signature
        XCTAssertEqual(Scan.cameraModes(options), [.signature])
    }

    func testEitherQRFlagOverridesEvenSignatureAndEmptyRestrictions() {
        for (transfer, mainQR) in [(true, false), (false, true), (true, true)] {
            for restriction: [Scan.CameraMode]? in [nil, [], [.singlePage, .multiplePages]] {
                let options = Scan.CameraOptions(supportsIdentityPhoto: true, electronicEvidenceEnabled: true,
                                                 signaturePicker: true, restrictedModes: restriction,
                                                 currentRestrictedMode: .signature,
                                                 transferWithoutPart: transfer, fromMainQRScan: mainQR)
                XCTAssertEqual(Scan.cameraModes(options), [.qrCode])
            }
        }
    }

    func testAdjustmentDefaultsRangesAndDraftValueSemantics() {
        let original = Scan.AdjustmentValues()
        XCTAssertEqual(original, .init(brightness: 0, contrast: 0, detail: 100))
        XCTAssertEqual(Scan.AdjustmentValues.brightnessRange, -50...50)
        XCTAssertEqual(Scan.AdjustmentValues.contrastRange, -50...50)
        XCTAssertEqual(Scan.AdjustmentValues.detailRange, 0...100)
        var draft = original
        draft.brightness = 25
        draft.contrast = -30
        draft.detail = 45
        XCTAssertNotEqual(draft, original)
        XCTAssertEqual(original, Scan.AdjustmentValues())
        // Discarding a value-type draft is not proof of editor cancellation.
        // The UI suite separately reopens the page and checks its sliders.
    }

    func testPixelAdjustmentNormalizationPreservesInclusiveEndpoints() {
        for value: Int32 in [-50, 0, 50] {
            let adjustment = ReconstructedAdjustmentContract(brightness: value, contrast: value, detail: 100)
            XCTAssertEqual(adjustment.brightness, value)
            XCTAssertEqual(adjustment.contrast, value)
        }
        for detail: Int32 in [0, 50, 100] {
            XCTAssertEqual(ReconstructedAdjustmentContract(brightness: 0, contrast: 0, detail: detail).detail, detail)
        }
    }

    func testInvalidPixelAdjustmentsResetToZeroRatherThanClampToAnEndpoint() {
        for value: Int32 in [Int32.min, -51, 51, Int32.max] {
            let adjustment = ReconstructedAdjustmentContract(brightness: value, contrast: value, detail: 100)
            XCTAssertEqual(adjustment.brightness, 0)
            XCTAssertEqual(adjustment.contrast, 0)
        }
        for detail: Int32 in [Int32.min, -1, 101, Int32.max] {
            XCTAssertEqual(ReconstructedAdjustmentContract(brightness: 0, contrast: 0, detail: detail).detail, 0)
        }
    }

    func testHistoricalToolbarHeightsAndEqualWidthFrames() {
        XCTAssertEqual(Toolbar.referenceHeight(usesIPhoneXLayout: false), 50)
        XCTAssertEqual(Toolbar.referenceHeight(usesIPhoneXLayout: true), 84)
        for width in [320.0, 390.0, 430.0, 768.0, 1024.0] {
            for height in [50.0, 51.99, 52.0, 84.0] {
                let frames = Toolbar.referenceFrames(width: width, height: height, itemCount: 5)
                XCTAssertEqual(frames.count, 5)
                for (index, frame) in frames.enumerated() {
                    XCTAssertEqual(frame.x, Double(index) * width / 5, accuracy: 0.000001)
                    XCTAssertEqual(frame.y, height < 52 ? 0 : 2)
                    XCTAssertEqual(frame.width, width / 5, accuracy: 0.000001)
                    XCTAssertEqual(frame.height, 50)
                }
                XCTAssertEqual(frames.reduce(0) { $0 + $1.width }, width, accuracy: 0.000001)
            }
        }
    }

    func testReferenceFramesHandleNoItemsWithoutDivision() {
        for count in [-1, 0] {
            XCTAssertTrue(Toolbar.referenceFrames(width: 390, height: 84, itemCount: count).isEmpty)
        }
        let frame = Toolbar.referenceFrames(width: 0, height: 50, itemCount: 1)
        XCTAssertEqual(frame.first?.width, 0)
        XCTAssertEqual(frame.first?.x, 0)
    }

    @MainActor
    func testConcreteToolbarDispatchesRawOperationsInEveryLayout() {
        let toolbar = makeToolbar()
        var received: [Int] = []
        toolbar.onOperation = { received.append($0.rawValue) }
        let cases: [(Toolbar.Layout, [Int])] = [
            (.crop, [17, 18, 19, 20]), (.legacyAfterProcess, [18, 21, 22, 23]),
            (.processed, [18, 77, 73, 79, 78, 21, 23]),
            (.adjustments, [80, 83, 82, 81, 23]), (.pageList, [50, 52, 5, 53, 51])
        ]
        for (layout, expected) in cases {
            received.removeAll()
            toolbar.configure(layout: layout)
            toolbar.layoutIfNeeded()
            let buttons = visibleButtons(in: toolbar)
            XCTAssertEqual(buttons.count, expected.count)
            buttons.forEach { $0.sendActions(for: .touchUpInside) }
            XCTAssertEqual(received, expected)
        }
    }

    @MainActor
    func testDisabledToolbarCannotDispatchAndRemainsDisabledAfterReconfiguration() {
        let toolbar = makeToolbar()
        var received: [Int] = []
        toolbar.onOperation = { received.append($0.rawValue) }
        toolbar.setEnabled(false)
        for layout: Toolbar.Layout in [.processed, .adjustments, .crop] {
            toolbar.configure(layout: layout)
            let buttons = visibleButtons(in: toolbar)
            XCTAssertFalse(buttons.isEmpty)
            XCTAssertTrue(buttons.allSatisfy { !$0.isEnabled })
            buttons.forEach { $0.sendActions(for: .touchUpInside) }
        }
        XCTAssertTrue(received.isEmpty)
        toolbar.setEnabled(true)
        visibleButtons(in: toolbar).forEach { $0.sendActions(for: .touchUpInside) }
        XCTAssertEqual(received, [17, 18, 19, 20])
    }

    @MainActor
    func testSelectionUsesAlternateTitleAndReconfigureClearsSelection() throws {
        let toolbar = makeToolbar()
        toolbar.configure(layout: .crop)
        let detect = try XCTUnwrap(visibleButtons(in: toolbar).first)
        XCTAssertEqual(detect.accessibilityLabel, "translated:cs_512_label_all")
        toolbar.setSelected(true, for: .detectBorders)
        XCTAssertTrue(detect.isSelected)
        XCTAssertEqual(detect.accessibilityLabel, "translated:cs_512_title_auto")
        toolbar.setSelected(false, for: .detectBorders)
        XCTAssertFalse(detect.isSelected)
        toolbar.setSelected(true, for: .detectBorders)
        toolbar.configure(layout: .crop, showTitles: false)
        let rebuilt = try XCTUnwrap(visibleButtons(in: toolbar).first)
        XCTAssertFalse(rebuilt.isSelected)
        XCTAssertNil(rebuilt.configuration?.title)
        XCTAssertEqual(rebuilt.accessibilityLabel, "translated:cs_512_label_all")
    }

    @MainActor
    func testProcessedToolbarKeepsDoneOutsideScrollableSixtyFivePointCells() throws {
        let toolbar = makeToolbar()
        toolbar.configure(layout: .processed)
        toolbar.layoutIfNeeded()
        let buttons = visibleButtons(in: toolbar)
        XCTAssertEqual(buttons.count, 7)
        let done = try XCTUnwrap(buttons.last)
        XCTAssertEqual(done.frame, CGRect(x: 324, y: 7, width: 56, height: 36))
        XCTAssertTrue(done.superview === toolbar)
        for (index, button) in buttons.dropLast().enumerated() {
            XCTAssertEqual(button.frame, CGRect(x: CGFloat(index) * 65, y: 0, width: 65, height: 50))
        }
        let strip = try XCTUnwrap(toolbar.subviews.compactMap { $0 as? UIScrollView }.first)
        XCTAssertEqual(strip.frame.width, 314)
        XCTAssertEqual(strip.contentSize.width, 390)
        XCTAssertTrue(strip.isScrollEnabled)
        strip.setContentOffset(CGPoint(x: 65, y: 0), animated: false)
        toolbar.configure(layout: .crop)
        toolbar.layoutIfNeeded()
        XCTAssertEqual(strip.contentOffset, .zero)
        XCTAssertFalse(strip.isScrollEnabled)
    }

    func testCancellingFirstAdjustmentRestoresNilRatherThanPersistingNeutralValues() {
        var state = EditorAdjustmentState()
        XCTAssertNil(state.committed)
        XCTAssertNil(state.effective)
        XCTAssertFalse(state.isEditing)
        XCTAssertEqual(state.draft, EditorAdjustmentState.neutral)

        state.begin()
        XCTAssertTrue(state.isEditing)
        XCTAssertEqual(state.effective, EditorAdjustmentState.neutral)
        state.set(.contrast, to: 35)
        state.set(.brightness, to: -20)
        state.set(.detail, to: 45)
        XCTAssertNil(state.committed, "A draft must not update the committed snapshot.")
        XCTAssertEqual(state.effective,
                       ReconstructedAdjustmentContract(brightness: -20, contrast: 35, detail: 45))

        state.cancel()
        XCTAssertFalse(state.isEditing)
        XCTAssertNil(state.committed)
        XCTAssertNil(state.effective)
        XCTAssertEqual(state.draft, EditorAdjustmentState.neutral)
        state.begin()
        XCTAssertEqual(state.draft, EditorAdjustmentState.neutral)
        state.cancel()
        XCTAssertNil(state.effective)
    }

    func testCancelRestoresAllPreviouslyCommittedControls() {
        let saved = ReconstructedAdjustmentContract(brightness: -13, contrast: 22, detail: 67)
        var state = EditorAdjustmentState(saved)
        state.begin()
        state.set(.brightness, to: 40)
        state.set(.contrast, to: -40)
        state.set(.detail, to: 10)
        XCTAssertEqual(state.committed, saved)
        XCTAssertNotEqual(state.effective, saved)

        state.cancel()
        XCTAssertFalse(state.isEditing)
        XCTAssertEqual(state.committed, saved)
        XCTAssertEqual(state.effective, saved)
        XCTAssertEqual(state.draft, saved)
        XCTAssertEqual(state.value(.brightness), -13)
        XCTAssertEqual(state.value(.contrast), 22)
        XCTAssertEqual(state.value(.detail), 67)
    }

    func testConfirmPromotesDraftAndNextCancelRestoresLatestCommit() {
        let original = ReconstructedAdjustmentContract(brightness: -5, contrast: 10, detail: 80)
        let confirmed = ReconstructedAdjustmentContract(brightness: 17, contrast: -23, detail: 41)
        var state = EditorAdjustmentState(original)
        state.begin()
        state.set(.brightness, to: 17)
        state.set(.contrast, to: -23)
        state.set(.detail, to: 41)
        XCTAssertEqual(state.committed, original)
        state.confirm()

        XCTAssertFalse(state.isEditing)
        XCTAssertEqual(state.committed, confirmed)
        XCTAssertEqual(state.effective, confirmed)
        state.cancel()
        XCTAssertEqual(state.committed, confirmed, "Cancel outside an edit must not undo a commit.")

        state.begin()
        XCTAssertEqual(state.draft, confirmed)
        state.set(.detail, to: 99)
        state.set(.brightness, to: -49)
        state.cancel()
        XCTAssertEqual(state.committed, confirmed)
        XCTAssertEqual(state.draft, confirmed)

        // Simulate reopening from saved metadata, without creating files or a store.
        let reopened = EditorAdjustmentState(state.committed)
        XCTAssertFalse(reopened.isEditing)
        XCTAssertEqual(reopened.effective, confirmed)
    }

    func testRepeatedBeginDoesNotReplaceSnapshotOrDiscardActiveDraft() {
        let original = ReconstructedAdjustmentContract(brightness: 8, contrast: -12, detail: 74)
        var state = EditorAdjustmentState(original)
        state.begin()
        state.set(.brightness, to: 31)
        state.selected = .brightness
        let active = state
        state.begin()
        XCTAssertEqual(state, active)
        state.set(.detail, to: 20)
        state.cancel()
        XCTAssertEqual(state.committed, original)
        XCTAssertEqual(state.draft, original)
    }

    func testInactiveAdjustmentCommandsAreNoOps() {
        for committed: ReconstructedAdjustmentContract? in [
            nil, ReconstructedAdjustmentContract(brightness: 12, contrast: -7, detail: 83)
        ] {
            var state = EditorAdjustmentState(committed)
            let before = state
            for control in EditorAdjustmentState.Control.allCases {
                state.set(control, to: 37)
            }
            state.confirm()
            state.cancel()
            XCTAssertEqual(state, before)
        }
    }

    func testActiveAdjustmentInputClampsRoundsAndRejectsNonFiniteValues() {
        var state = EditorAdjustmentState()
        state.begin()
        XCTAssertEqual(EditorAdjustmentState.range(.brightness), -50...50)
        XCTAssertEqual(EditorAdjustmentState.range(.contrast), -50...50)
        XCTAssertEqual(EditorAdjustmentState.range(.detail), 0...100)

        for control in EditorAdjustmentState.Control.allCases {
            let range = EditorAdjustmentState.range(control)
            state.set(control, to: -Double.greatestFiniteMagnitude)
            XCTAssertEqual(state.value(control), range.lowerBound)
            state.set(control, to: Double.greatestFiniteMagnitude)
            XCTAssertEqual(state.value(control), range.upperBound)
        }
        state.set(.brightness, to: -12.5)
        state.set(.contrast, to: 12.5)
        state.set(.detail, to: 65.4)
        XCTAssertEqual(state.value(.brightness), -13)
        XCTAssertEqual(state.value(.contrast), 13)
        XCTAssertEqual(state.value(.detail), 65)

        let beforeInvalidInput = state
        for control in EditorAdjustmentState.Control.allCases {
            for value in [Double.nan, Double.infinity, -Double.infinity] {
                state.set(control, to: value)
                XCTAssertEqual(state, beforeInvalidInput)
            }
        }
        XCTAssertNil(state.committed)
    }

    func testPreviewRevisionAcceptsOnlyCurrentTokenAndRejectsOlderAndFutureTokens() {
        var revision = EditorPreviewRevision()
        XCTAssertEqual(revision.current, 0)
        XCTAssertTrue(revision.accepts(0))
        XCTAssertFalse(revision.accepts(1))
        let first = revision.advance()
        let second = revision.advance()
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertFalse(revision.accepts(0))
        XCTAssertFalse(revision.accepts(first))
        XCTAssertFalse(revision.accepts(second + 1))
        XCTAssertTrue(revision.accepts(second))
        XCTAssertTrue(revision.accepts(second), "Checking a token must not consume or advance it.")
        XCTAssertEqual(revision.current, second)
    }

    func testOutOfOrderPreviewCompletionCannotReplaceTheNewestPreview() {
        var revision = EditorPreviewRevision()
        let oldDraft = revision.advance()
        let newerDraft = revision.advance()
        let restoredOrCommitted = revision.advance()

        // A caller must advance when restoring/committing state. This tests the
        // pure acceptance gate, not renderer scheduling or UI wiring.
        let completionOrder = [newerDraft, restoredOrCommitted, oldDraft]
        var accepted: [UInt64] = []
        var displayed: UInt64?
        for token in completionOrder where revision.accepts(token) {
            accepted.append(token)
            displayed = token
        }
        XCTAssertEqual(accepted, [restoredOrCommitted])
        XCTAssertEqual(displayed, restoredOrCommitted)

        let nextEdit = revision.advance()
        XCTAssertFalse(revision.accepts(restoredOrCommitted))
        XCTAssertTrue(revision.accepts(nextEdit))
    }

    private func plan(_ operation: Toolbar.Operation, status: Int, zoom: Double = 1,
                      ocr: Bool = false) -> Toolbar.ActionPlan {
        Toolbar.plan(operation, nativeStatus: status, zoomScale: zoom, pageContainsOCR: ocr)
    }

    private func assertIntent(_ actual: Toolbar.Intent, equals expected: Toolbar.Intent,
                              file: StaticString = #filePath, line: UInt = #line) {
        switch (actual, expected) {
        case (.deletePage, .deletePage), (.detectBorders, .detectBorders),
             (.rotateLeft, .rotateLeft), (.rotateRight, .rotateRight),
             (.clearOCRAndProcessCrop, .clearOCRAndProcessCrop), (.recognizeText, .recognizeText),
             (.showAdjustments, .showAdjustments), (.confirmAdjustments, .confirmAdjustments),
             (.savePage, .savePage), (.retakePhoto, .retakePhoto),
             (.continueCapture, .continueCapture), (.smudgePage, .smudgePage),
             (.showSignature, .showSignature), (.addCapture, .addCapture),
             (.showTextWatermark, .showTextWatermark), (.cancelAdjustments, .cancelAdjustments),
             (.noAction, .noAction): break
        case let (.rotateProcessedPage(actual), .rotateProcessedPage(expected)):
            XCTAssertEqual(actual, expected, file: file, line: line)
        case let (.enterInkNote(actual), .enterInkNote(expected)):
            XCTAssertEqual(actual, expected, file: file, line: line)
        case let (.selectAdjustment(actual), .selectAdjustment(expected)):
            XCTAssertEqual(actual, expected, file: file, line: line)
        default:
            XCTFail("Expected \(expected), received \(actual)", file: file, line: line)
        }
    }

    @MainActor
    private func makeToolbar() -> RecoveredEditorToolbar {
        let toolbar = RecoveredEditorToolbar(titleForKey: { "translated:\($0)" },
                                              imageForName: { _ in nil }, accent: .systemGreen, surface: .white)
        toolbar.frame = CGRect(x: 0, y: 0, width: 390, height: 84)
        return toolbar
    }

    @MainActor
    private func visibleButtons(in view: UIView) -> [UIButton] {
        view.subviews.flatMap { child -> [UIButton] in
            guard !child.isHidden else { return [] }
            if let button = child as? UIButton { return [button] }
            return visibleButtons(in: child)
        }
    }
}
