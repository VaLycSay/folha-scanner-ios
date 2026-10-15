import CoreGraphics
import XCTest
@testable import Folha

final class LiveDocumentCaptureGateTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 600)
    private let inside = [CGPoint(x: 80, y: 70), CGPoint(x: 320, y: 70),
                          CGPoint(x: 320, y: 520), CGPoint(x: 80, y: 520)]

    func testFreshAndSmoothedCornersBothInsidePermitFraming() {
        XCTAssertTrue(LiveDocumentCaptureGate.isFramed(current: inside, smoothed: inside, inside: bounds))
    }

    func testFreshCornerOutsideRejectsEvenWhileSmoothedOverlayLooksInside() {
        var fresh = inside
        fresh[1] = CGPoint(x: 397, y: 70)
        XCTAssertFalse(LiveDocumentCaptureGate.isFramed(current: fresh, smoothed: inside, inside: bounds))
    }

    func testOverlayOutsideAlsoRejectsUntilItSettles() {
        var overlay = inside
        overlay[0] = CGPoint(x: -5, y: 70)
        XCTAssertFalse(LiveDocumentCaptureGate.isFramed(current: inside, smoothed: overlay, inside: bounds))
    }

    func testMissingCurrentObservationCannotUseAStaleOverlay() {
        XCTAssertFalse(LiveDocumentCaptureGate.isFramed(current: [], smoothed: inside, inside: bounds))
        XCTAssertFalse(LiveDocumentCaptureGate.isFramed(current: Array(inside.prefix(3)), smoothed: inside, inside: bounds))
    }

    func testInvalidFrameAndCoordinatesFailClosed() {
        var bad = inside
        bad[0] = CGPoint(x: CGFloat.nan, y: 70)
        XCTAssertFalse(LiveDocumentCaptureGate.isFramed(current: bad, smoothed: inside, inside: bounds))
        XCTAssertFalse(LiveDocumentCaptureGate.isFramed(current: inside, smoothed: inside, inside: .zero))
        XCTAssertFalse(LiveDocumentCaptureGate.isFramed(current: inside, smoothed: inside, inside: bounds, margin: .infinity))
    }
}
