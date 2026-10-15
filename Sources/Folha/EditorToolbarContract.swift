// Independently written contract derived from private static REA evidence.
// Reference only: CamScanner 5.26.12. Not a running application or an SDK.
// Original artwork is not bundled. This source has not been compiled or tested.
// Reference binary SHA-256: df2346e1e6fa1fa6c96970f53493f1488d9a1631d471e0baec6cea6ebf062528

public enum RecoveredEditorToolbarContract {
    public enum Operation: Int, CaseIterable {
        case deletePage = 5
        case detectBorders = 17
        case rotateLeft = 18
        case rotateRight = 19
        case processCrop = 20
        case recognizeText = 21
        case fineTune = 22
        case done = 23
        case retake = 50
        case continueCapture = 51
        case smudgePage = 52
        case fineTunePage = 53
        case signature = 73
        case addCapture = 74
        case textWatermark = 77
        case annotation = 78
        case smudgeEditor = 79
        case cancelAdjustment = 80
        case detail = 81
        case brightness = 82
        case contrast = 83
    }

    public struct Descriptor {
        public let localizedTitleKey: String?
        public let selectedTitleKey: String?
        public let referenceImageName: String?
        public let nativeAction: String
    }

    public static let descriptors: [Operation: Descriptor] = [
        .deletePage: Descriptor(localizedTitleKey: "i_button_title_delete", selectedTitleKey: nil, referenceImageName: "ic_delete_24px", nativeAction: "editDelete:"),
        .detectBorders: Descriptor(localizedTitleKey: "cs_512_label_all", selectedTitleKey: "cs_512_title_auto", referenceImageName: "ic_all_trimming_24px", nativeAction: "findBorder:"),
        .rotateLeft: Descriptor(localizedTitleKey: "cs_5100_button_book_left", selectedTitleKey: nil, referenceImageName: "ic_left_turn_24px", nativeAction: "rotateLeft: / rotateAfterProcess:"),
        .rotateRight: Descriptor(localizedTitleKey: "cs_5100_button_book_right", selectedTitleKey: nil, referenceImageName: "ic_right_turn_24px", nativeAction: "rotateRight:"),
        .processCrop: Descriptor(localizedTitleKey: "c_sign_btn_next_step", selectedTitleKey: nil, referenceImageName: "ic_next_step_24px", nativeAction: "clear OCR fields -> process:"),
        .recognizeText: Descriptor(localizedTitleKey: "cs_523_button_ocr", selectedTitleKey: nil, referenceImageName: "ic_ocr_24px", nativeAction: "processOCR:"),
        .fineTune: Descriptor(localizedTitleKey: "Fine Tune", selectedTitleKey: nil, referenceImageName: "ic_fine_tuning_24px", nativeAction: "showPanel:"),
        .done: Descriptor(localizedTitleKey: "Save", selectedTitleKey: nil, referenceImageName: "ic_done_24px", nativeAction: "status 3: commit adjustments; otherwise done:"),
        .retake: Descriptor(localizedTitleKey: "retake", selectedTitleKey: nil, referenceImageName: "ic_remake_24px", nativeAction: "retakePhoto:"),
        .continueCapture: Descriptor(localizedTitleKey: "Continue shoot", selectedTitleKey: nil, referenceImageName: "ic_camera_add_24px", nativeAction: "continueToShoot:"),
        .smudgePage: Descriptor(localizedTitleKey: "Smudge", selectedTitleKey: nil, referenceImageName: "ic_apply_24px", nativeAction: "smudgeOperation:"),
        .fineTunePage: Descriptor(localizedTitleKey: "Fine Tune", selectedTitleKey: nil, referenceImageName: "ic_fine_tuning_24px", nativeAction: "showPanel:"),
        .signature: Descriptor(localizedTitleKey: "cs_5205_signature", selectedTitleKey: nil, referenceImageName: "ic_autograph_24px", nativeAction: "showSignatureView"),
        .addCapture: Descriptor(localizedTitleKey: "cs_522_add", selectedTitleKey: nil, referenceImageName: "ic_camera_24px", nativeAction: "takeAnotherImage + popViewControllerAnimated:"),
        .textWatermark: Descriptor(localizedTitleKey: "cs_523_button_text", selectedTitleKey: nil, referenceImageName: "ic_add_font_20px", nativeAction: "CSMultiWaterMarkViewController"),
        .annotation: Descriptor(localizedTitleKey: "cs_523_button_annotation", selectedTitleKey: nil, referenceImageName: "ic_handwriting_20px", nativeAction: "enterInkNoteWithInkoNoteMode: 0"),
        .smudgeEditor: Descriptor(localizedTitleKey: "cs_523_button_smudge", selectedTitleKey: nil, referenceImageName: "ic_apply_24px", nativeAction: "enterInkNoteWithInkoNoteMode: 1"),
        .cancelAdjustment: Descriptor(localizedTitleKey: nil, selectedTitleKey: nil, referenceImageName: "switch_app_icon_close", nativeAction: "showToolbar: 2 + setPanelToolbarItemHidden: 1"),
        .detail: Descriptor(localizedTitleKey: "cs_512_label_adjust_detail", selectedTitleKey: nil, referenceImageName: "ic_detail", nativeAction: "panelType 81 -> panelToolbarItemChangeClick:"),
        .brightness: Descriptor(localizedTitleKey: "Brightness", selectedTitleKey: nil, referenceImageName: "ic_brightness", nativeAction: "panelType 82 -> panelToolbarItemChangeClick:"),
        .contrast: Descriptor(localizedTitleKey: "Contrast", selectedTitleKey: nil, referenceImageName: "ic_contrast", nativeAction: "panelType 83 -> panelToolbarItemChangeClick:")
    ]

    public enum Layout { case crop, legacyAfterProcess, processed, adjustments, pageList }
    public struct LayoutSpec {
        public let items: [Operation]
        public let separateDone: Operation?
    }

    // Raw mode 10 and viewType 1 are specific to this historical binary.
    // Their broader product names have not been inferred.
    public static func layout(_ layout: Layout, referenceMode: Int = 0, viewType: Int = 0) -> LayoutSpec {
        switch layout {
        case .crop:
            return LayoutSpec(items: referenceMode == 10 ? [.detectBorders, .rotateLeft, .addCapture, .rotateRight, .processCrop] : [.detectBorders, .rotateLeft, .rotateRight, .processCrop], separateDone: nil)
        case .legacyAfterProcess:
            return LayoutSpec(items: viewType == 1 ? [.rotateLeft, .fineTune, .done] : [.rotateLeft, .recognizeText, .fineTune, .done], separateDone: nil)
        case .processed:
            return LayoutSpec(items: [.rotateLeft, .textWatermark, .signature, .smudgeEditor, .annotation, .recognizeText], separateDone: .done)
        case .adjustments:
            return LayoutSpec(items: [.cancelAdjustment, .contrast, .brightness, .detail, .done], separateDone: nil)
        case .pageList:
            return LayoutSpec(items: [.retake, .smudgePage, .deletePage, .fineTunePage, .continueCapture], separateDone: nil)
        }
    }

    public enum Intent {
        case deletePage, detectBorders, rotateLeft, rotateRight
        case rotateProcessedPage(requiresOCRConfirmation: Bool)
        case clearOCRAndProcessCrop, recognizeText, showAdjustments
        case confirmAdjustments, savePage, retakePhoto, continueCapture
        case smudgePage, showSignature, addCapture, showTextWatermark
        case enterInkNote(mode: Int), cancelAdjustments
        case selectAdjustment(Operation), noAction
    }

    public struct ActionPlan {
        public let resetZoomFirst: Bool
        public let intent: Intent
    }

    // Produces an intent only. It does not save, delete, perform OCR, or mutate an image.
    public static func plan(_ operation: Operation, nativeStatus: Int, zoomScale: Double,
                            pageContainsOCR: Bool) -> ActionPlan {
        let intent: Intent
        switch operation {
        case .deletePage: intent = .deletePage
        case .detectBorders: intent = .detectBorders
        case .rotateLeft:
            if nativeStatus == 2 { intent = .rotateProcessedPage(requiresOCRConfirmation: pageContainsOCR) }
            else if nativeStatus == 0 { intent = .rotateLeft }
            else { intent = .noAction }
        case .rotateRight: intent = .rotateRight
        case .processCrop: intent = .clearOCRAndProcessCrop
        case .recognizeText: intent = .recognizeText
        case .fineTune, .fineTunePage: intent = .showAdjustments
        case .done: intent = nativeStatus == 3 ? .confirmAdjustments : .savePage
        case .retake: intent = .retakePhoto
        case .continueCapture: intent = .continueCapture
        case .smudgePage: intent = .smudgePage
        case .signature: intent = .showSignature
        case .addCapture: intent = .addCapture
        case .textWatermark: intent = .showTextWatermark
        case .annotation: intent = .enterInkNote(mode: 0)
        case .smudgeEditor: intent = .enterInkNote(mode: 1)
        case .cancelAdjustment: intent = .cancelAdjustments
        case .detail, .brightness, .contrast: intent = .selectAdjustment(operation)
        }
        // The native dispatcher exempts raw operation IDs 18 and 22 from zoom reset.
        let reset = nativeStatus == 2 && zoomScale != 1.0 && operation != .rotateLeft && operation != .fineTune
        return ActionPlan(resetZoomFirst: reset, intent: intent)
    }

    public struct ItemFrame {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
    }

    // Historical CSToolBar geometry, not a device detector for a modern iPhone.
    public static func referenceHeight(usesIPhoneXLayout: Bool) -> Double {
        usesIPhoneXLayout ? 84.0 : 50.0
    }
    public static func referenceFrames(width: Double, height: Double, itemCount: Int) -> [ItemFrame] {
        guard itemCount > 0 else { return [] }
        let itemWidth = width / Double(itemCount)
        return (0..<itemCount).map { ItemFrame(x: Double($0) * itemWidth, y: height < 52.0 ? 0.0 : 2.0,
                                             width: itemWidth, height: 50.0) }
    }
}
