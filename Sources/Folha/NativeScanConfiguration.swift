// Independently written from static REA evidence for CamScanner 5.26.12.
// UI configuration only. No camera, image engine, OCR, or original assets.
// Camera-toolbar IDs, image-picker modes, and editor modes are separate enums.

public enum NativeScanConfiguration {
    public enum CameraMode: Int, CaseIterable {
        case greetingCard = 0
        case identityDocument = 1
        case singlePage = 2
        case multiplePages = 3
        case qrCode = 4
        case questionBook = 5
        case signature = 6
        case textRecognition = 7
        case electronicEvidence = 8
        case spreadsheetRecognition = 9
        case identityPhoto = 10
        case more = 11

        public var titleKey: String {
            switch self {
            case .greetingCard: return "Greeting Card"
            case .identityDocument: return "ID Card"
            case .singlePage: return "i_label_camera_single_mode"
            case .multiplePages: return "i_label_camera_batch_mode"
            case .qrCode: return "QR Code"
            case .questionBook: return "Question book"
            case .signature: return "  "
            case .textRecognition: return "cs_522_text_ocr"
            case .electronicEvidence: return "electronic evidence"
            case .spreadsheetRecognition: return "cs_522_excel_ocr"
            case .identityPhoto: return "cs_595_id_photo"
            case .more: return "i_button_title_more"
            }
        }

        public var nativeAction: String {
            switch self {
            case .greetingCard: return "greetingCardModeAction:"
            case .identityDocument: return "certificateModeButtonDidClicked:"
            case .singlePage: return "singleModeButtonDidClicked:"
            case .multiplePages: return "multiModeButtonDidClicked:"
            case .qrCode: return "qrCodeModeButtonDidClicked:"
            case .questionBook: return "wrongQuestionModeButtonDidClicked:"
            case .signature: return "signatureModeButtonDidClicked:"
            case .textRecognition: return "OCRModeButtonDidClicked:"
            case .electronicEvidence: return "electricProofModeButtonDidClicked:"
            case .spreadsheetRecognition: return "excelModeButtonDidClicked:"
            case .identityPhoto: return "cardPhotoItemDidClicked:"
            case .more: return "moreModeAction:"
            }
        }
    }

    public struct CameraOptions {
        public var supportsIdentityPhoto: Bool
        public var electronicEvidenceEnabled: Bool
        // Corresponds to image-picker mode 9, not camera-toolbar mode 9.
        public var signaturePicker: Bool
        // Nil means no restriction; an empty list deliberately stays empty.
        public var restrictedModes: [CameraMode]?
        public var currentRestrictedMode: CameraMode?
        public var transferWithoutPart: Bool
        public var fromMainQRScan: Bool

        public init(supportsIdentityPhoto: Bool, electronicEvidenceEnabled: Bool,
                    signaturePicker: Bool = false, restrictedModes: [CameraMode]? = nil,
                    currentRestrictedMode: CameraMode? = nil, transferWithoutPart: Bool = false,
                    fromMainQRScan: Bool = false) {
            self.supportsIdentityPhoto = supportsIdentityPhoto
            self.electronicEvidenceEnabled = electronicEvidenceEnabled
            self.signaturePicker = signaturePicker
            self.restrictedModes = restrictedModes
            self.currentRestrictedMode = currentRestrictedMode
            self.transferWithoutPart = transferWithoutPart
            self.fromMainQRScan = fromMainQRScan
        }
    }

    // The native parser of remote mode strings is not reproduced here.
    // Callers supply an already resolved list; no private API is contacted.
    public static func cameraModes(_ options: CameraOptions) -> [CameraMode] {
        var modes: [CameraMode] = [.spreadsheetRecognition, .textRecognition,
            .identityDocument, .singlePage, .multiplePages, .questionBook, .qrCode,
            .more, .greetingCard, .electronicEvidence]
        if options.supportsIdentityPhoto { modes.insert(.identityPhoto, at: 1) }
        if !options.electronicEvidenceEnabled {
            modes.removeAll { $0 == .greetingCard || $0 == .more || $0 == .electronicEvidence }
            modes.insert(.greetingCard, at: 0)
        }
        if options.signaturePicker { modes = [.signature] }
        if let restricted = options.restrictedModes {
            modes = restricted
            if let current = options.currentRestrictedMode, !modes.contains(current) {
                modes.append(current)
            }
        }
        if options.transferWithoutPart || options.fromMainQRScan { modes = [.qrCode] }
        return modes
    }

    public enum Filter: Int, CaseIterable {
        case original = 0, lighten = 1, magicColor = 2
        case blackAndWhite2 = 3, grayscale = 4, blackAndWhite = 5, removeShadow = 6

        public var titleKey: String {
            switch self {
            case .original: return "Original"
            case .lighten: return "Lighten"
            case .magicColor: return "Magic Color"
            case .blackAndWhite: return "B&W"
            case .blackAndWhite2: return "B&W 2"
            case .grayscale: return "Grayscale"
            case .removeShadow: return "no_cs_520c_remove_shadow"
            }
        }
    }

    public static func filters(removeShadowEnabled: Bool) -> [Filter] {
        let base: [Filter] = [.original, .lighten, .magicColor, .blackAndWhite, .blackAndWhite2, .grayscale]
        return removeShadowEnabled ? [.removeShadow] + base : base
    }

    public static func initialFilter(previousRawValue: Int?, supportsMultipleImages: Bool,
                                     available: [Filter]) -> Filter? {
        let preferred = supportsMultipleImages ? Filter.magicColor.rawValue : previousRawValue ?? 0
        return available.first { $0.rawValue == preferred } ?? available.first
    }

    public struct AdjustmentValues: Equatable {
        public var brightness: Float
        public var contrast: Float
        public var detail: Float
        public init(brightness: Float = 0, contrast: Float = 0, detail: Float = 100) {
            self.brightness = brightness
            self.contrast = contrast
            self.detail = detail
        }
        public static let brightnessRange: ClosedRange<Float> = -50...50
        public static let contrastRange: ClosedRange<Float> = -50...50
        public static let detailRange: ClosedRange<Float> = 0...100
    }
}
