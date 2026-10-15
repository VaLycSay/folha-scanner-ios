import Foundation
import CoreGraphics

// Pure state: no camera, store, renderer or network is instantiated by these types.
enum EditorStage: Int { case crop = 0, processed = 2, adjustments = 3 }

struct EditorAdjustmentState: Equatable {
    enum Control: CaseIterable { case contrast, brightness, detail }
    static let neutral = ReconstructedAdjustmentContract(brightness: 0, contrast: 0, detail: 100)
    private(set) var committed: ReconstructedAdjustmentContract?
    private(set) var draft: ReconstructedAdjustmentContract
    private(set) var isEditing = false
    private var snapshot: ReconstructedAdjustmentContract?
    var selected: Control = .contrast

    init(_ value: ReconstructedAdjustmentContract? = nil) {
        committed = value
        draft = value ?? Self.neutral
    }
    var effective: ReconstructedAdjustmentContract? { isEditing ? draft : committed }
    mutating func begin() {
        guard !isEditing else { return }
        snapshot = committed
        draft = committed ?? Self.neutral
        isEditing = true
    }
    func value(_ control: Control) -> Double {
        switch control {
        case .contrast: return Double(draft.contrast)
        case .brightness: return Double(draft.brightness)
        case .detail: return Double(draft.detail)
        }
    }
    static func range(_ control: Control) -> ClosedRange<Double> {
        control == .detail ? 0...100 : -50...50
    }
    mutating func set(_ control: Control, to value: Double) {
        guard isEditing, value.isFinite else { return }
        let range = Self.range(control)
        let bounded = Int32(min(range.upperBound, max(range.lowerBound, value)).rounded())
        draft = ReconstructedAdjustmentContract(
            brightness: control == .brightness ? bounded : draft.brightness,
            contrast: control == .contrast ? bounded : draft.contrast,
            detail: control == .detail ? bounded : draft.detail)
    }
    mutating func confirm() {
        guard isEditing else { return }
        committed = draft
        snapshot = nil
        isEditing = false
    }
    mutating func cancel() {
        guard isEditing else { return }
        committed = snapshot
        draft = committed ?? Self.neutral
        snapshot = nil
        isEditing = false
    }
}

struct EditorPreviewRevision {
    private(set) var current: UInt64 = 0
    @discardableResult mutating func advance() -> UInt64 { current &+= 1; return current }
    func accepts(_ revision: UInt64) -> Bool { current == revision }
}

enum EditorFilterCatalog {
    // Six recovered slots; shadow removal is separately identified in the UI.
    static var recoveredOrder: [PageFilter] {
        NativeScanConfiguration.filters(removeShadowEnabled: false).map(pageFilter)
    }
    static func pageFilter(_ filter: NativeScanConfiguration.Filter) -> PageFilter {
        switch filter {
        case .original: return .natural
        case .lighten: return .lighten
        case .magicColor: return .clean
        case .blackAndWhite: return .document
        case .blackAndWhite2: return .blackAndWhite2
        case .grayscale: return .grayscale
        case .removeShadow: return .removeShadow
        }
    }
    static func nativeModeID(_ filter: PageFilter) -> Int {
        switch filter {
        case .natural: return 0
        case .lighten: return 1
        case .clean: return 2
        case .document: return 5
        case .blackAndWhite2: return 3
        case .grayscale: return 4
        case .removeShadow: return 6
        }
    }
    static func title(_ filter: PageFilter) -> String {
        switch filter {
        case .natural: return "Original"
        case .lighten: return "Clarear"
        case .clean: return "Cor"
        case .document: return "P&B"
        case .blackAndWhite2: return "P&B 2"
        case .grayscale: return "Cinza"
        case .removeShadow: return "Sem sombra*"
        }
    }
}

enum EditorGeometry {
    static var fullPage: PageCorners {
        PageCorners(topLeft: .init(CGPoint(x: 0, y: 1)), topRight: .init(CGPoint(x: 1, y: 1)),
                    bottomLeft: .init(CGPoint(x: 0, y: 0)), bottomRight: .init(CGPoint(x: 1, y: 0)))
    }
    // Source corners use Vision's LOWER-LEFT origin. Overlay points use TOP-LEFT.
    static func vertices(_ corners: PageCorners) -> [UnitPointRecord] {
        [corners.topLeft, corners.topRight, corners.bottomRight, corners.bottomLeft]
    }
    static func isValid(_ corners: PageCorners) -> Bool {
        let points = vertices(corners)
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
            (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return false }
        var area = 0.0
        var crosses: [Double] = []
        for index in 0..<4 {
            let a = points[index], b = points[(index + 1) % 4], c = points[(index + 2) % 4]
            area += a.x * b.y - b.x * a.y
            crosses.append((b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x))
        }
        // Preserve winding; reject mirrored, crossed, concave or degenerate handles.
        return area < -0.002 && crosses.allSatisfy { $0 < -0.000001 }
    }
    static func rotateTopLeft(_ point: CGPoint, quarterTurns: Int) -> CGPoint {
        switch (quarterTurns % 4 + 4) % 4 {
        case 1: return CGPoint(x: 1 - point.y, y: point.x)
        case 2: return CGPoint(x: 1 - point.x, y: 1 - point.y)
        case 3: return CGPoint(x: point.y, y: 1 - point.x)
        default: return point
        }
    }
    static func displayPoint(_ point: UnitPointRecord, quarterTurns: Int) -> CGPoint {
        rotateTopLeft(CGPoint(x: point.x, y: 1 - point.y), quarterTurns: quarterTurns)
    }
    static func sourcePoint(_ point: CGPoint, quarterTurns: Int) -> UnitPointRecord {
        let bounded = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
        let unrotated = rotateTopLeft(bounded, quarterTurns: -quarterTurns)
        return UnitPointRecord(CGPoint(x: unrotated.x, y: 1 - unrotated.y))
    }
    static func replacing(_ corners: PageCorners, index: Int, point: UnitPointRecord) -> PageCorners {
        var result = corners
        switch index {
        case 0: result.topLeft = point
        case 1: result.topRight = point
        case 2: result.bottomRight = point
        case 3: result.bottomLeft = point
        default: break
        }
        return result
    }
    static func fittedSize(_ size: CGSize, inside bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
    static func rectangle(from start: CGPoint, to end: CGPoint) -> CGRect {
        let a = CGPoint(x: min(1, max(0, start.x)), y: min(1, max(0, start.y)))
        let b = CGPoint(x: min(1, max(0, end.x)), y: min(1, max(0, end.y)))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    static func visibleOCR(_ lines: [OCRLine], overlays: [PageOverlay]) -> [OCRLine] {
        let redactions = overlays.filter { $0.kind == .redaction }.map {
            CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }
        // Defense in depth for the transcript. PDF redaction remains ScanEngine's responsibility.
        return lines.filter { line in
            let box = CGRect(x: line.x, y: 1 - line.y - line.height, width: line.width, height: line.height)
            return !redactions.contains { $0.intersects(box) }
        }
    }
}
