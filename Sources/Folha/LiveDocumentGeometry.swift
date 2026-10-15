import CoreGraphics
import Foundation

/// Corners in normalized, portrait-oriented Vision coordinates (origin bottom-left).
/// Size, edge clipping and confidence policy belong to the detector, not this type.
struct LiveDocumentQuad: Equatable {
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomRight: CGPoint
    let bottomLeft: CGPoint

    init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    var points: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    var area: CGFloat {
        let corners = points
        guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return 0 }
        let twiceArea = corners.indices.reduce(CGFloat.zero) { result, index in
            let a = corners[index]
            let b = corners[(index + 1) % corners.count]
            return result + a.x * b.y - b.x * a.y
        }
        return twiceArea.isFinite ? abs(twiceArea) / 2 : 0
    }

    var isValid: Bool {
        let corners = points
        guard corners.allSatisfy({
            $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)
        }), area > 1e-8 else { return false }

        // All four turns must be nonzero and have the same winding. This rejects
        // repeated/collinear corners, concavity and crossing edges in either winding.
        let turns = corners.indices.map { index -> CGFloat in
            let a = corners[index]
            let b = corners[(index + 1) % 4]
            let c = corners[(index + 2) % 4]
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        }
        return turns.allSatisfy { $0 > 1e-10 } || turns.allSatisfy { $0 < -1e-10 }
    }

    /// BACK camera: unrotated sensor buffer, Vision .right, portrait preview at 90 degrees.
    /// Pass the result to previewLayer.layerPointConverted(fromCaptureDevicePoint:).
    /// No mirroring, aspect-fill adjustment or clamping is performed here.
    static func captureDevicePoint(fromPortraitVision point: CGPoint) -> CGPoint {
        CGPoint(x: 1 - point.y, y: 1 - point.x)
    }

    static func portraitVisionPoint(fromCaptureDevice point: CGPoint) -> CGPoint {
        CGPoint(x: 1 - point.y, y: 1 - point.x)
    }

    func interpolated(toward other: Self, alpha: CGFloat) -> Self {
        guard alpha.isFinite else { return self }
        let amount = min(1, max(0, alpha))
        func blend(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * amount, y: a.y + (b.y - a.y) * amount)
        }
        return Self(topLeft: blend(topLeft, other.topLeft),
                    topRight: blend(topRight, other.topRight),
                    bottomRight: blend(bottomRight, other.bottomRight),
                    bottomLeft: blend(bottomLeft, other.bottomLeft))
    }

    func maximumDistance(to other: Self) -> CGFloat {
        zip(points, other.points).reduce(CGFloat.zero) { maximum, pair in
            let dx = pair.0.x - pair.1.x
            let dy = pair.0.y - pair.1.y
            guard dx.isFinite && dy.isFinite else { return .infinity }
            return max(maximum, (dx * dx + dy * dy).squareRoot())
        }
    }
}

struct LiveDocumentTrackingState: Equatable {
    let quad: LiveDocumentQuad?
    let stable: Bool
    let progress: Double
    let awaitingClear: Bool
}

/// Pure state machine; its owner serializes updates (the camera uses the main thread).
/// Feed nil only for an actual completed detection with no document, never a paused
/// detector, skipped frame or inference error. Invalid geometry is not proof of removal.
struct LiveDocumentTracker {
    private let stableDuration: TimeInterval
    private let minimumSamples: Int
    private let movementTolerance: CGFloat
    private let lossGrace: TimeInterval
    private let rearmDelay: TimeInterval

    // A pause cannot contribute elapsed stability time or prove the sheet was removed.
    // Detection samples must arrive at least twice per second to form one continuous run.
    private static let maximumSampleGap: TimeInterval = 0.5
    private static let smoothingAlpha: CGFloat = 0.35

    private var visualQuad: LiveDocumentQuad?
    private var anchor: LiveDocumentQuad?
    private var stableSince: TimeInterval?
    private var sampleCount = 0
    private var lastUpdate: TimeInterval?
    private var lastDetection: TimeInterval?
    private var clearSince: TimeInterval?
    private var clearSamples = 0
    private var awaitingClear = false

    init(stableDuration: TimeInterval = 0.85, minimumSamples: Int = 5,
         movementTolerance: CGFloat = 0.018, lossGrace: TimeInterval = 0.25,
         rearmDelay: TimeInterval = 0.8) {
        self.stableDuration = stableDuration.isFinite ? max(0, stableDuration) : 0.85
        self.minimumSamples = max(1, minimumSamples)
        self.movementTolerance = movementTolerance.isFinite ? max(0, movementTolerance) : 0.018
        self.lossGrace = lossGrace.isFinite ? max(0, lossGrace) : 0.25
        self.rearmDelay = rearmDelay.isFinite ? max(0, rearmDelay) : 0.8
    }

    mutating func update(_ quad: LiveDocumentQuad?, at time: TimeInterval) -> LiveDocumentTrackingState {
        guard time.isFinite else {
            restartObservations()
            return state()
        }
        if let previous = lastUpdate,
           time <= previous || time - previous > Self.maximumSampleGap {
            // Preserve the capture latch across interruptions, rollback and repeated
            // timestamps. Equal timestamps cannot count as independent samples.
            restartObservations()
        }
        lastUpdate = time

        guard let detected = quad, detected.isValid else {
            restartStability()
            if lastDetection.map({ time - $0 >= lossGrace }) ?? true { visualQuad = nil }
            if awaitingClear && quad == nil {
                if clearSince == nil { clearSince = time }
                clearSamples += 1
                if let start = clearSince, clearSamples >= 2, time - start >= rearmDelay {
                    awaitingClear = false
                    clearSince = nil
                    clearSamples = 0
                }
            } else {
                clearSince = nil
                clearSamples = 0
            }
            return state()
        }

        clearSince = nil
        clearSamples = 0
        lastDetection = time
        let blended = visualQuad?.interpolated(toward: detected, alpha: Self.smoothingAlpha)
        visualQuad = blended.flatMap { $0.isValid ? $0 : nil } ?? detected

        guard !awaitingClear else {
            restartStability()
            return state()
        }
        if anchor == nil || anchor!.maximumDistance(to: detected) > movementTolerance {
            anchor = detected
            stableSince = time
            sampleCount = 1
        } else {
            // Compare raw coordinates with the fixed anchor, never the smoothed
            // overlay or previous frame: many small steps must not hide a large drift.
            sampleCount += 1
        }
        let elapsed = time - (stableSince ?? time)
        let timeProgress = stableDuration == 0 ? 1 : min(1, elapsed / stableDuration)
        let samplesProgress = min(1, Double(sampleCount) / Double(minimumSamples))
        return state(stable: elapsed >= stableDuration && sampleCount >= minimumSamples,
                     progress: min(timeProgress, samplesProgress))
    }

    mutating func markCaptured(at time: TimeInterval) {
        awaitingClear = true
        restartStability()
        clearSince = nil
        clearSamples = 0
        // Do not restart the observation clock here: a photo pause must be detected
        // by the next update, even when a late capture callback supplies a new time.
        if !time.isFinite { restartObservations() }
    }

    /// Explicit new-session/user reset only. Do NOT call for temporary camera pauses.
    mutating func reset() {
        restartObservations()
        awaitingClear = false
    }

    private mutating func restartStability() {
        anchor = nil
        stableSince = nil
        sampleCount = 0
    }

    private mutating func restartObservations() {
        restartStability()
        visualQuad = nil
        lastDetection = nil
        lastUpdate = nil
        clearSince = nil
        clearSamples = 0
        // Intentionally leave awaitingClear unchanged.
    }

    private func state(stable: Bool = false, progress: Double = 0) -> LiveDocumentTrackingState {
        LiveDocumentTrackingState(quad: visualQuad, stable: stable,
                                  progress: progress, awaitingClear: awaitingClear)
    }
}
