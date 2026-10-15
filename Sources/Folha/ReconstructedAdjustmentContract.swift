import Foundation

/// Independent implementation of a bounded behavior recovered from the
/// historical scanner's ARM64 argument-normalization prefix.
/// This is not the original image transform and is not wired to the editor yet.
struct ReconstructedAdjustmentContract: Codable, Equatable, Sendable {
    let brightness: Int32
    let contrast: Int32
    let detail: Int32

    init(brightness: Int32, contrast: Int32, detail: Int32) {
        self.brightness = (-50...50).contains(brightness) ? brightness : 0
        self.contrast = (-50...50).contains(contrast) ? contrast : 0
        self.detail = (0...100).contains(detail) ? detail : 0
    }
}
