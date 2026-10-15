import SwiftUI
import UIKit

// Wrap the recovered UIView: preserve 65x50 scrolling cells and separate 56x36 Done.
struct EditorNativeToolbar: UIViewRepresentable {
    typealias Contract = RecoveredEditorToolbarContract
    typealias Operation = Contract.Operation
    let layout: Contract.Layout
    var enabled = true
    var selected: Set<Operation> = []
    var disabledOperations: Set<Operation> = []
    var imageProvider: ((String) -> UIImage?)? = nil
    let onOperation: (Operation) -> Void

    final class Coordinator { var layoutKey = "" }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> RecoveredEditorToolbar {
        let provider = imageProvider
        let toolbar = RecoveredEditorToolbar(titleForKey: Self.title,
            imageForName: { name in provider?(name) ?? Self.symbol(name) },
            accent: .systemGreen, surface: .secondarySystemBackground)
        toolbar.accessibilityIdentifier = "editor.toolbar"
        toolbar.isAccessibilityElement = false
        return toolbar
    }
    func updateUIView(_ toolbar: RecoveredEditorToolbar, context: Context) {
        let key = String(describing: layout)
        if context.coordinator.layoutKey != key {
            // configure resets horizontal scroll; do not repeat it on slider updates.
            toolbar.configure(layout: layout)
            context.coordinator.layoutKey = key
        }
        toolbar.onOperation = onOperation
        toolbar.setEnabled(enabled)
        for operation in Operation.allCases { toolbar.setSelected(selected.contains(operation), for: operation) }
        let spec = Contract.layout(layout)
        let buttons = Self.buttons(in: toolbar)
        // Recovered hierarchy: strip buttons in contract order, then separate Done.
        for (operation, button) in zip(spec.items, buttons) {
            button.accessibilityIdentifier = Self.identifier(operation, adjusting: key == "adjustments")
            button.accessibilityLabel = Self.label(operation, adjusting: key == "adjustments")
            button.tintColor = selected.contains(operation) ? .systemGreen : .label
            button.isEnabled = enabled && !disabledOperations.contains(operation)
        }
        if let operation = spec.separateDone, let button = buttons.last {
            button.accessibilityIdentifier = Self.identifier(operation, adjusting: false)
            button.accessibilityLabel = "Salvar pagina"
            button.tintColor = .white
            button.isEnabled = enabled && !disabledOperations.contains(operation)
        }
    }
    private static func buttons(in view: UIView) -> [UIButton] {
        if let button = view as? UIButton { return [button] }
        return view.subviews.flatMap { buttons(in: $0) }
    }
    static func identifier(_ operation: Operation, adjusting: Bool) -> String {
        switch operation {
        case .processCrop: return "editor.process"
        case .done: return adjusting ? "editor.confirm-adjustments" : "editor.save"
        case .cancelAdjustment: return "editor.cancel-adjustments"
        case .textWatermark: return "editor.text"
        case .annotation: return "editor.annotation"
        case .signature: return "editor.signature"
        case .smudgeEditor, .smudgePage: return "editor.redact"
        case .recognizeText: return "editor.ocr"
        case .fineTune, .fineTunePage: return "editor.adjustments"
        case .rotateLeft: return "editor.rotate-left"
        case .rotateRight: return "editor.rotate-right"
        case .detectBorders: return "editor.detect-borders"
        case .contrast: return "editor.adjustment.contrast"
        case .brightness: return "editor.adjustment.brightness"
        case .detail: return "editor.adjustment.detail"
        default: return "editor.operation.\(operation.rawValue)"
        }
    }
    private static func label(_ operation: Operation, adjusting: Bool) -> String {
        if operation == .cancelAdjustment { return "Cancelar ajustes" }
        if operation == .done { return adjusting ? "Confirmar ajustes" : "Salvar pagina" }
        if let key = Contract.descriptors[operation]?.localizedTitleKey { return title(key) }
        return String(describing: operation)
    }
    private static func title(_ key: String) -> String {
        ["i_button_title_delete": "Excluir", "cs_512_label_all": "Bordas",
         "cs_512_title_auto": "Automatico", "cs_5100_button_book_left": "Esquerda",
         "cs_5100_button_book_right": "Direita", "c_sign_btn_next_step": "Avancar",
         "cs_523_button_ocr": "Texto OCR", "Fine Tune": "Ajustes", "Save": "Salvar",
         "retake": "Refazer", "Continue shoot": "Continuar", "Smudge": "Ocultar",
         "cs_5205_signature": "Assinar", "cs_522_add": "Adicionar",
         "cs_523_button_text": "Texto", "cs_523_button_annotation": "Anotar",
         "cs_523_button_smudge": "Ocultar", "cs_512_label_adjust_detail": "Detalhe",
         "Brightness": "Brilho", "Contrast": "Contraste"][key] ?? key
    }
    private static func symbol(_ name: String) -> UIImage? {
        let symbols = ["ic_delete_24px": "trash", "ic_all_trimming_24px": "viewfinder",
            "ic_left_turn_24px": "rotate.left", "ic_right_turn_24px": "rotate.right",
            "ic_next_step_24px": "arrow.right", "ic_ocr_24px": "text.viewfinder",
            "ic_fine_tuning_24px": "slider.horizontal.3", "ic_done_24px": "checkmark",
            "ic_remake_24px": "camera.rotate", "ic_camera_add_24px": "camera.badge.ellipsis",
            "ic_apply_24px": "rectangle.fill", "ic_autograph_24px": "signature",
            "ic_camera_24px": "camera", "ic_add_font_20px": "textformat",
            "ic_handwriting_20px": "pencil.tip", "switch_app_icon_close": "xmark",
            "ic_detail": "circle.lefthalf.filled", "ic_brightness": "sun.max",
            "ic_contrast": "circle.righthalf.filled"]
        return UIImage(systemName: symbols[name] ?? "square")
    }
}
