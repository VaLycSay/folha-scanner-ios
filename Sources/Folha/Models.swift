import Foundation
import CoreGraphics
import UIKit

enum ScanConfiguration {
    // Product defaults, not parameters recovered from CamScanner.
    static let maximumWorkingDimension: CGFloat = 3200
    static let thumbnailDimension: CGFloat = 320
    static let cameraJPEGQuality: CGFloat = 0.97
    static let workingJPEGQuality: CGFloat = 0.92
    static let preferredOCRLanguages = ["pt-BR", "en-US"]
    static let pageSize = CGSize(width: 595.28, height: 841.89)
    static let pageMargin: CGFloat = 20
}

enum PageFilter: String, Codable, CaseIterable, Identifiable {
    case natural, clean, grayscale, document
    case lighten, blackAndWhite2, removeShadow
    var id: String { rawValue }
    // Recovered selector IDs/order, not evidence of identical native processing.
    static var recoveredOrder: [PageFilter] = [.natural, .lighten, .clean, .document, .blackAndWhite2, .grayscale]
    var nativeModeID: Int {
        switch self {
        case .natural: return 0
        case .lighten: return 1
        case .clean: return 2
        case .document: return 5
        case .blackAndWhite2: return 3
        case .grayscale: return 4
        case .removeShadow: return 6
        }
    }
    var implementationNote: String {
        "Implementacao independente aproximada; nao e processamento nativo identico ao CamScanner."
    }
    var title: String {
        switch self {
        case .natural: return "Original"
        case .clean: return "Cor magica"
        case .grayscale: return "Cinza"
        case .document: return "P&B"
        case .lighten: return "Clarear"
        case .blackAndWhite2: return "P&B 2"
        case .removeShadow: return "Remover sombras"
        }
    }
}

struct UnitPointRecord: Codable, Hashable {
    var x: Double
    var y: Double
    init(_ point: CGPoint) { x = point.x; y = point.y }
    var point: CGPoint { CGPoint(x: x, y: y) }
}

struct PageCorners: Codable, Hashable {
    // Vision coordinates: normalized, origin at lower-left.
    var topLeft: UnitPointRecord
    var topRight: UnitPointRecord
    var bottomLeft: UnitPointRecord
    var bottomRight: UnitPointRecord
}

enum PageOverlayKind: String, Codable { case text, ink, redaction }

struct PageOverlay: Codable, Hashable, Identifiable {
    // Normalized top-left coordinates on the final cropped/rotated page.
    // These are deliberately NOT the bottom-left coordinates used by Vision.
    var id = UUID()
    var kind: PageOverlayKind
    var text: String? = nil
    var points: [UnitPointRecord] = []
    var x: Double = 0.1
    var y: Double = 0.1
    var width: Double = 0.5
    var height: Double = 0.15
    var lineWidth: Double = 0.006
}

struct OCRLine: Codable, Hashable, Identifiable {
    var id = UUID()
    var text: String
    var confidence: Float
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var bounds: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct ScanPage: Codable, Hashable, Identifiable {
    var reconstructedAdjustments: ReconstructedAdjustmentContract? = nil
    // Optional for manifests written before overlays were introduced.
    var overlays: [PageOverlay]? = nil
    var id: UUID
    var sourceFile: String
    var renderedFile: String
    var thumbnailFile: String
    var filter: PageFilter = .natural
    var quarterTurns = 0
    var autoCrop = false
    var corners: PageCorners?
    var lines: [OCRLine] = []
    var ocrWarning: String?
    var width: Int = 0
    var height: Int = 0
}

struct ScanDocument: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var updatedAt = Date()
    var pages: [ScanPage] = []
    var searchableText: String { pages.flatMap(\.lines).map(\.text).joined(separator: "\n") }
}

struct CapturedScanPage: Hashable {
    var data: Data
    var corners: PageCorners?
    var filter: PageFilter = .clean
    var autoCrop: Bool = true
}

enum ScanInput {
    case camera(UIImage)
    case rawCamera(UIImage)
    case photo(Data)
    case scannedPage(Data, corners: PageCorners? = nil, filter: PageFilter = .clean, autoCrop: Bool = true)

    func bytes() throws -> Data {
        switch self {
        case .photo(let data), .scannedPage(let data, _, _, _): return data
        case .camera(let image), .rawCamera(let image):
            guard let data = image.jpegData(compressionQuality: ScanConfiguration.cameraJPEGQuality) else {
                throw ScanFailure.message("Nao foi possivel guardar a imagem capturada.")
            }
            return data
        }
    }

    var autoCrop: Bool {
        switch self {
        case .camera: return false // VisionKit has already offered crop correction.
        case .photo, .rawCamera: return true
        case .scannedPage(_, _, _, let crop): return crop
        }
    }

    var initialCorners: PageCorners? {
        switch self {
        case .scannedPage(_, let corners, _, _): return corners
        default: return nil
        }
    }

    var initialFilter: PageFilter {
        switch self {
        case .scannedPage(_, _, let filter, _): return filter
        default: return .natural
        }
    }
}

enum ScanFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}
