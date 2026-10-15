import XCTest
import UIKit
import Vision
@testable import Folha

@MainActor
final class LiveDocumentVisionTests: XCTestCase {
    private func fixture(paper: Bool) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1100), format: format).image { context in
            UIColor(white: 0.12, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 1100))
            if paper {
                UIColor.white.setFill()
                context.fill(CGRect(x: 150, y: 150, width: 500, height: 800))
                UIColor(white: 0.3, alpha: 1).setFill()
                for y in stride(from: 250, through: 800, by: 65) {
                    context.fill(CGRect(x: 210, y: y, width: 350, height: 6))
                }
            }
        }
        return try XCTUnwrap(image.cgImage)
    }

    func testVisionActuallyDetectsSyntheticSheetRatherThanReturningFixedGuide() throws {
        let quad = try XCTUnwrap(LiveDocumentDetector.detect(in: fixture(paper: true)))
        XCTAssertTrue(quad.isValid)
        XCTAssertEqual(quad.topLeft.x, 150.0 / 800, accuracy: 0.045)
        XCTAssertEqual(quad.topLeft.y, 1 - 150.0 / 1100, accuracy: 0.045)
        XCTAssertEqual(quad.bottomRight.x, 650.0 / 800, accuracy: 0.045)
        XCTAssertEqual(quad.bottomRight.y, 1 - 950.0 / 1100, accuracy: 0.045)
        let shot = XCTAttachment(image: UIImage(cgImage: try fixture(paper: true)))
        shot.name = "REA-live-detection-synthetic-input"; shot.lifetime = .keepAlways; add(shot)
    }

    func testUniformSceneDoesNotBecomeDocument() throws {
        XCTAssertNil(try LiveDocumentDetector.detect(in: fixture(paper: false)))
    }

    func testVisionRightOrientationMapsAsymmetricCornersBackToUnrotatedSensor() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1100, height: 800), format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1100, height: 800))
            UIColor.white.setFill()
            context.fill(CGRect(x: 160, y: 120, width: 700, height: 440))
        }
        let quad = try XCTUnwrap(LiveDocumentDetector.detect(in: XCTUnwrap(image.cgImage), orientation: .right))
        let topLeft = LiveDocumentQuad.captureDevicePoint(fromPortraitVision: quad.topLeft)
        let bottomRight = LiveDocumentQuad.captureDevicePoint(fromPortraitVision: quad.bottomRight)
        // With clockwise orientation, upright top-left came from sensor bottom-left.
        XCTAssertEqual(topLeft.x, 160.0 / 1100, accuracy: 0.045)
        XCTAssertEqual(topLeft.y, 560.0 / 800, accuracy: 0.045)
        XCTAssertEqual(bottomRight.x, 860.0 / 1100, accuracy: 0.045)
        XCTAssertEqual(bottomRight.y, 120.0 / 800, accuracy: 0.045)
    }

    func testEmptyObservationsDoNotInventCorners() {
        XCTAssertNil(LiveDocumentDetector.bestQuad(in: []))
    }

    func testRequestIsBoundedAndThrottled() {
        let request = LiveDocumentDetector.makeRequest()
        XCTAssertEqual(request.maximumObservations, 4)
        XCTAssertGreaterThanOrEqual(request.minimumConfidence, 0.6)
        XCTAssertGreaterThanOrEqual(LiveDocumentDetector.frameInterval, 0.1)
    }
}
