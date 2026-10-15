import AVFoundation
import Vision
import ImageIO
import QuartzCore

// Independent Vision implementation, not recovered CamScanner algorithms.
// Sensor buffers stay unrotated; .right describes the rear camera in portrait.
// Work is serial, bounded in frequency, and never retains a frame backlog.
final class LiveDocumentDetector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let frameInterval: TimeInterval = 0.14
    let queue = DispatchQueue(label: "com.valyc.scanner.live-document", qos: .userInitiated)
    var onResult: ((LiveDocumentQuad?, String?) -> Void)?
    private let lock = NSLock()
    private var enabled = false
    private var generation: UInt = 0
    private var lastGeneration: UInt = 0
    private var lastFrameTime: TimeInterval = -.infinity

    func setEnabled(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if enabled != value { enabled = value; generation &+= 1 }
    }

    private func activeGeneration() -> UInt? {
        lock.lock()
        defer { lock.unlock() }
        return enabled ? generation : nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let current = activeGeneration(), CMSampleBufferDataIsReady(sampleBuffer),
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()
        if current != lastGeneration { lastFrameTime = -.infinity; lastGeneration = current }
        guard now - lastFrameTime >= Self.frameInterval else { return }
        lastFrameTime = now
        autoreleasepool {
            do {
                let request = Self.makeRequest()
                try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right, options: [:]).perform([request])
                publish(Self.bestQuad(in: request.results ?? []), error: nil, generation: current)
            } catch {
                publish(nil, error: error.localizedDescription, generation: current)
            }
        }
    }

    private func publish(_ quad: LiveDocumentQuad?, error: String?, generation: UInt) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeGeneration() == generation else { return }
            self.onResult?(quad, error)
        }
    }

    static func makeRequest() -> VNDetectRectanglesRequest {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 4
        request.minimumConfidence = 0.65
        request.minimumSize = 0.18
        request.minimumAspectRatio = 0.25
        request.maximumAspectRatio = 1
        request.quadratureTolerance = 25
        return request
    }

    static func bestQuad(in observations: [VNRectangleObservation]) -> LiveDocumentQuad? {
        observations.compactMap { rectangle -> (LiveDocumentQuad, CGFloat)? in
            let quad = LiveDocumentQuad(topLeft: rectangle.topLeft, topRight: rectangle.topRight,
                bottomRight: rectangle.bottomRight, bottomLeft: rectangle.bottomLeft)
            guard rectangle.confidence >= 0.65, quad.isValid, quad.area >= 0.08 else { return nil }
            let center = CGPoint(x: quad.points.map(\.x).reduce(0, +) / 4,
                                 y: quad.points.map(\.y).reduce(0, +) / 4)
            let distance = hypot(center.x - 0.5, center.y - 0.5)
            let score = quad.area * CGFloat(rectangle.confidence) * (1 - min(distance, 0.7) * 0.3)
            return (quad, score)
        }.max(by: { $0.1 < $1.1 })?.0
    }

    // Used by synthetic Vision tests with the same request/selection policy.
    // It is not a simulated successful camera callback.
    static func detect(in image: CGImage, orientation: CGImagePropertyOrientation = .up) throws -> LiveDocumentQuad? {
        let request = makeRequest()
        try VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]).perform([request])
        return bestQuad(in: request.results ?? [])
    }
}
