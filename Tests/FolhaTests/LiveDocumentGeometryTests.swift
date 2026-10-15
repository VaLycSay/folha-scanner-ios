import CoreGraphics
import XCTest
@testable import Folha

final class LiveDocumentGeometryTests: XCTestCase {
    private func rectangle(x: CGFloat = 0.2, y: CGFloat = 0.2,
                           width: CGFloat = 0.6, height: CGFloat = 0.6) -> LiveDocumentQuad {
        LiveDocumentQuad(topLeft: CGPoint(x: x, y: y + height),
                         topRight: CGPoint(x: x + width, y: y + height),
                         bottomRight: CGPoint(x: x + width, y: y),
                         bottomLeft: CGPoint(x: x, y: y))
    }

    @discardableResult
    private func makeStable(_ tracker: inout LiveDocumentTracker) -> LiveDocumentTrackingState {
        var result = tracker.update(rectangle(), at: 0)
        for tick in 1...5 { result = tracker.update(rectangle(), at: Double(tick) * 0.2) }
        XCTAssertTrue(result.stable)
        return result
    }

    func testNormalizedRectangleAreaAndCornerOrder() {
        let quad = rectangle()
        XCTAssertTrue(quad.isValid)
        XCTAssertEqual(quad.area, 0.36, accuracy: 1e-12)
        XCTAssertEqual(quad.points, [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft])
    }

    func testGeometryDoesNotImposeDetectorClippingOrDocumentSizePolicy() {
        XCTAssertTrue(rectangle(x: 0, y: 0, width: 1, height: 1).isValid)
        XCTAssertTrue(rectangle(width: 0.001, height: 0.001).isValid)
        XCTAssertFalse(rectangle(width: 1e-6, height: 1e-6).isValid)
    }

    func testRejectsNonFiniteAndOutOfRangeCorners() {
        for point in [CGPoint(x: -0.01, y: 0.8), CGPoint(x: 0.2, y: 1.01),
                      CGPoint(x: CGFloat.nan, y: 0.8), CGPoint(x: 0.2, y: CGFloat.infinity)] {
            let base = rectangle()
            let quad = LiveDocumentQuad(topLeft: point, topRight: base.topRight,
                                        bottomRight: base.bottomRight, bottomLeft: base.bottomLeft)
            XCTAssertFalse(quad.isValid)
        }
    }

    func testRejectsCrossedConcaveRepeatedAndCollinearCorners() {
        let q = rectangle()
        let invalid = [
            LiveDocumentQuad(topLeft: q.topLeft, topRight: q.bottomRight,
                             bottomRight: q.topRight, bottomLeft: q.bottomLeft),
            LiveDocumentQuad(topLeft: q.topLeft, topRight: CGPoint(x: 0.3, y: 0.4),
                             bottomRight: q.bottomRight, bottomLeft: q.bottomLeft),
            LiveDocumentQuad(topLeft: q.topLeft, topRight: q.topLeft,
                             bottomRight: q.bottomRight, bottomLeft: q.bottomLeft),
            rectangle(height: 0)
        ]
        for quad in invalid { XCTAssertFalse(quad.isValid) }
    }

    func testAcceptsConvexPerspectiveQuadAndEitherWinding() {
        let q = LiveDocumentQuad(topLeft: CGPoint(x: 0.15, y: 0.9),
                                 topRight: CGPoint(x: 0.8, y: 0.75),
                                 bottomRight: CGPoint(x: 0.9, y: 0.1),
                                 bottomLeft: CGPoint(x: 0.25, y: 0.2))
        XCTAssertTrue(q.isValid)
        XCTAssertTrue(LiveDocumentQuad(topLeft: q.topLeft, topRight: q.bottomLeft,
                                      bottomRight: q.bottomRight, bottomLeft: q.topRight).isValid)
    }

    func testBackCameraUnrotatedBufferMappingIsNotMirrored() {
        let point = CGPoint(x: 0.2, y: 0.7)
        let mapped = LiveDocumentQuad.captureDevicePoint(fromPortraitVision: point)
        XCTAssertEqual(mapped.x, 0.3, accuracy: 1e-12)
        XCTAssertEqual(mapped.y, 0.8, accuracy: 1e-12)
        XCTAssertEqual(LiveDocumentQuad.captureDevicePoint(fromPortraitVision: CGPoint(x: 0, y: 1)),
                       CGPoint(x: 0, y: 1))
        XCTAssertEqual(LiveDocumentQuad.captureDevicePoint(fromPortraitVision: CGPoint(x: 1, y: 1)),
                       CGPoint(x: 0, y: 0))
    }

    func testCoordinateMappingRoundTripsCornersAndAsymmetricPoints() {
        for point in [CGPoint.zero, CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1),
                      CGPoint(x: 1, y: 0), CGPoint(x: 0.24, y: 0.61), CGPoint(x: 0.5, y: 0.5)] {
            let device = LiveDocumentQuad.captureDevicePoint(fromPortraitVision: point)
            let result = LiveDocumentQuad.portraitVisionPoint(fromCaptureDevice: device)
            XCTAssertEqual(result.x, point.x, accuracy: 1e-12)
            XCTAssertEqual(result.y, point.y, accuracy: 1e-12)
        }
    }

    func testInterpolationClampsAlphaAndDistanceUsesFarthestCorner() {
        let a = rectangle()
        let b = rectangle(x: 0.3)
        XCTAssertEqual(a.interpolated(toward: b, alpha: -1), a)
        XCTAssertLessThan(a.interpolated(toward: b, alpha: 2).maximumDistance(to: b), 1e-12)
        XCTAssertEqual(a.interpolated(toward: b, alpha: .nan), a)
        XCTAssertEqual(a.interpolated(toward: b, alpha: 0.5).topLeft.x, 0.25, accuracy: 1e-12)
        XCTAssertEqual(a.maximumDistance(to: b), 0.1, accuracy: 1e-12)
        let oneCorner = LiveDocumentQuad(topLeft: CGPoint(x: 0.23, y: 0.84), topRight: a.topRight,
                                        bottomRight: a.bottomRight, bottomLeft: a.bottomLeft)
        XCTAssertEqual(a.maximumDistance(to: oneCorner), 0.05, accuracy: 1e-12)
    }

    func testSmallJitterAroundFixedAnchorBecomesStable() {
        var tracker = LiveDocumentTracker()
        let offsets: [CGFloat] = [0, 0.005, -0.006, 0.008, -0.007, 0.004]
        for (index, offset) in offsets.enumerated() {
            let result = tracker.update(rectangle(x: 0.2 + offset), at: Double(index) * 0.2)
            XCTAssertEqual(result.stable, index == 5)
            XCTAssertTrue((0...1).contains(result.progress))
        }
    }

    func testCumulativeDriftCannotBecomeStableEvenWhenEveryStepIsSmall() {
        var tracker = LiveDocumentTracker()
        for index in 0...20 {
            let result = tracker.update(rectangle(x: 0.2 + CGFloat(index) * 0.006),
                                        at: Double(index) * 0.2)
            XCTAssertFalse(result.stable, "Cumulative drift at sample \(index) must restart the anchor")
        }
    }

    func testOverlayIsSmoothedButLargeMovementImmediatelyResetsStability() {
        var tracker = LiveDocumentTracker()
        makeStable(&tracker)
        let moved = rectangle(x: 0.3)
        let result = tracker.update(moved, at: 1.2)
        XCTAssertFalse(result.stable)
        XCTAssertEqual(result.progress, 0)
        XCTAssertEqual(result.quad!.topLeft.x, 0.235, accuracy: 1e-12)
        XCTAssertNotEqual(result.quad, moved)
    }

    func testBothDurationAndSampleCountAreRequired() {
        var tracker = LiveDocumentTracker(stableDuration: 0.1, minimumSamples: 5)
        for index in 0..<4 {
            XCTAssertFalse(tracker.update(rectangle(), at: Double(index) * 0.1).stable)
        }
        XCTAssertTrue(tracker.update(rectangle(), at: 0.4).stable)
    }

    func testLossImmediatelyResetsStabilityButOverlayHasGracePeriod() {
        var tracker = LiveDocumentTracker()
        makeStable(&tracker)
        let briefLoss = tracker.update(nil, at: 1.1)
        XCTAssertFalse(briefLoss.stable)
        XCTAssertEqual(briefLoss.progress, 0)
        XCTAssertNotNil(briefLoss.quad)
        XCTAssertNil(tracker.update(nil, at: 1.3).quad)
        let recovered = tracker.update(rectangle(), at: 1.4)
        XCTAssertFalse(recovered.stable)
        XCTAssertEqual(recovered.progress, 0)
    }

    func testFrameGapRestartsStabilityAndDoesNotBlendStaleOverlay() {
        var tracker = LiveDocumentTracker()
        makeStable(&tracker)
        let fresh = rectangle(x: 0.3)
        let result = tracker.update(fresh, at: 20)
        XCTAssertFalse(result.stable)
        XCTAssertEqual(result.progress, 0)
        XCTAssertEqual(result.quad, fresh)
    }

    func testTimestampRollbackAndDuplicatesCannotProduceBogusStability() {
        var tracker = LiveDocumentTracker()
        makeStable(&tracker)
        XCTAssertEqual(tracker.update(rectangle(), at: 0.5).progress, 0)
        XCTAssertFalse(tracker.update(rectangle(), at: 0.7).stable)
        var duplicates = LiveDocumentTracker(stableDuration: 0, minimumSamples: 5)
        for _ in 0..<20 { XCTAssertFalse(duplicates.update(rectangle(), at: 10).stable) }
    }

    func testCaptureLatchPreventsSameSheetRepeatsAcrossLongCapturePause() {
        var tracker = LiveDocumentTracker()
        makeStable(&tracker)
        tracker.markCaptured(at: 1)
        for index in 0...15 {
            let result = tracker.update(rectangle(), at: 20 + Double(index) * 0.2)
            XCTAssertTrue(result.awaitingClear)
            XCTAssertFalse(result.stable)
            XCTAssertEqual(result.progress, 0)
        }
    }

    func testBriefLossDoesNotRearmAndReappearanceRestartsClearWindow() {
        var tracker = LiveDocumentTracker()
        makeStable(&tracker)
        tracker.markCaptured(at: 1)
        XCTAssertTrue(tracker.update(nil, at: 1.1).awaitingClear)
        XCTAssertTrue(tracker.update(nil, at: 1.3).awaitingClear)
        XCTAssertTrue(tracker.update(rectangle(), at: 1.4).awaitingClear)
        for time in [1.5, 1.8, 2.1, 2.2] {
            XCTAssertTrue(tracker.update(nil, at: time).awaitingClear)
        }
        XCTAssertFalse(tracker.update(nil, at: 2.4).awaitingClear)
        XCTAssertFalse(tracker.update(rectangle(), at: 2.5).stable)
        var next = tracker.update(rectangle(), at: 2.7)
        for time in [2.9, 3.1, 3.3, 3.5] { next = tracker.update(rectangle(), at: time) }
        XCTAssertTrue(next.stable)
        XCTAssertFalse(next.awaitingClear)
    }

    func testLongGapBetweenNilObservationsIsNotSustainedDocumentRemoval() {
        var tracker = LiveDocumentTracker()
        tracker.markCaptured(at: 0)
        for time in [0.1, 0.4, 10.0, 10.3, 10.6] {
            XCTAssertTrue(tracker.update(nil, at: time).awaitingClear)
        }
        XCTAssertFalse(tracker.update(nil, at: 10.9).awaitingClear)
    }

    func testRollbackPreservesLatchAndRestartsClearWindow() {
        var tracker = LiveDocumentTracker()
        tracker.markCaptured(at: 1)
        for time in [1.1, 1.4, 0.2, 0.5, 0.8] {
            XCTAssertTrue(tracker.update(nil, at: time).awaitingClear)
        }
        XCTAssertFalse(tracker.update(nil, at: 1.1).awaitingClear)
    }

    func testInvalidGeometryNeverCountsAsNoDocumentToRearm() {
        var tracker = LiveDocumentTracker()
        makeStable(&tracker)
        tracker.markCaptured(at: 1)
        XCTAssertTrue(tracker.update(nil, at: 1.1).awaitingClear)
        let invalid = rectangle(height: 0)
        for index in 0...10 {
            let state = tracker.update(invalid, at: 1.2 + Double(index) * 0.2)
            XCTAssertTrue(state.awaitingClear)
            XCTAssertFalse(state.stable)
        }
        XCTAssertTrue(tracker.update(nil, at: 3.4).awaitingClear)
    }

    func testInvalidTimestampClearsProgressButPreservesCaptureLatch() {
        var tracker = LiveDocumentTracker()
        makeStable(&tracker)
        tracker.markCaptured(at: 1)
        for time in [TimeInterval.nan, TimeInterval.infinity] {
            let result = tracker.update(nil, at: time)
            XCTAssertTrue(result.awaitingClear)
            XCTAssertFalse(result.stable)
            XCTAssertEqual(result.progress, 0)
            XCTAssertNil(result.quad)
        }
        XCTAssertTrue(tracker.update(nil, at: 20).awaitingClear)
    }

    func testZeroRearmDelayStillRequiresTwoRealNilObservations() {
        var tracker = LiveDocumentTracker(rearmDelay: 0)
        tracker.markCaptured(at: 0)
        XCTAssertTrue(tracker.update(nil, at: 0.1).awaitingClear)
        XCTAssertFalse(tracker.update(nil, at: 0.2).awaitingClear)
    }

    func testExplicitResetClearsCaptureLatchForANewSession() {
        var tracker = LiveDocumentTracker()
        makeStable(&tracker)
        tracker.markCaptured(at: 1)
        tracker.reset()
        let result = tracker.update(rectangle(), at: 2)
        XCTAssertFalse(result.awaitingClear)
        XCTAssertFalse(result.stable)
        XCTAssertEqual(result.progress, 0)
    }
}
