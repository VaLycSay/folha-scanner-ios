// Presentation policy for the independently implemented editor. This is not
// recovered runtime code. Current resource labels and historical operation
// contracts inform it; the exact modern editor navigation remains unobserved.
enum EditorBackAction: Equatable {
    case leaveEditor, cancelCrop, cancelAdjustments
}

enum EditorPresentation {
    static func backAction(stage: EditorStage, cropReturnsToProcessed: Bool) -> EditorBackAction {
        switch stage {
        case .adjustments: return .cancelAdjustments
        case .crop: return cropReturnsToProcessed ? .cancelCrop : .leaveEditor
        case .processed: return .leaveEditor
        }
    }

    static func filterTitle(_ filter: PageFilter) -> String {
        // NativeScanConfiguration maps magicColor to .clean. The current
        // pt-BR resource "Magic Color" is "Cor Magica" (accent encoded below).
        if filter == .clean { return "Cor M\u{00E1}gica" }
        return EditorFilterCatalog.title(filter)
    }
}
