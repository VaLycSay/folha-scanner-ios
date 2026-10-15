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
    var id: String { rawValue }
    var title: String {
        switch self {
        case .natural: return "Original"
        case .clean: return "Nitido"
        case .grayscale: return "Cinza"
        case .document: return "Documento"
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

enum ScanInput {
    case camera(UIImage)
    case photo(Data)

    func bytes() throws -> Data {
        switch self {
        case .photo(let data): return data
        case .camera(let image):
            guard let data = image.jpegData(compressionQuality: ScanConfiguration.cameraJPEGQuality) else {
                throw ScanFailure.message("Nao foi possivel guardar a imagem capturada.")
            }
            return data
        }
    }

    var autoCrop: Bool {
        switch self {
        case .camera: return false // VisionKit has already offered crop correction.
        case .photo: return true
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
