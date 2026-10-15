import Foundation

enum RecoveredPixelAdjustment {
    enum Failure: Error { case invalidRGBA }

    /// Independent reconstruction of the historical RGBA adjustment path.
    /// The synthetic comparison excludes cancellation callbacks and other formats.
    static func applyRGBA(_ input: [UInt8], width: Int, height: Int,
                          settings: ReconstructedAdjustmentContract) throws -> [UInt8] {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              input.count == width * height * 4 else { throw Failure.invalidRGBA }
        let b = Int(settings.brightness), c = Int(settings.contrast), d = Int(settings.detail)
        let exponent = Double(c) / (c < 0 ? 60.0 : 10.0) + 1.0
        let lower = (0..<128).map { Float(pow(Double($0) / 128.0, exponent) * 128.0) }
        var curve = lower
        curve.append(128)
        curve.append(contentsOf: (129..<255).map { Float(255) - lower[255 - $0] })
        curve.append(255)
        let gain: Float = b < 0 ? Float(b + 60) / 60 : 60 / Float(60 - b)
        let base = curve.map { min(255, Int(Double(gain * Float(Int(Double($0) + 0.5))) + 0.5)) }
        var histogram = [Int](repeating: 0, count: 4096)
        for i in stride(from: 0, to: input.count, by: 4) {
            let bucket = (Int(input[i + 2]) >> 4) * 256
                + (Int(input[i + 1]) & 0xf0) + (Int(input[i]) >> 4)
            histogram[bucket] += 1
        }
        var dominant = 0
        for i in 1..<histogram.count where histogram[i] > histogram[dominant] { dominant = i }
        let red = flatten(base, center: (dominant & 15) * 16, detail: d)
        let green = flatten(base, center: dominant & 0xf0, detail: d)
        let blue = flatten(base, center: (dominant >> 8) * 16, detail: d)
        var result = input
        for i in stride(from: 0, to: input.count, by: 4) {
            var r = red[Int(input[i])]
            let g = green[Int(input[i + 1])]
            var b = blue[Int(input[i + 2])]
            if r >= 226 && g >= 226 { r = g; b = g }
            result[i] = UInt8(r)
            result[i + 1] = UInt8(g)
            result[i + 2] = UInt8(b)
        }
        return result
    }

    private static func flatten(_ source: [Int], center: Int, detail: Int) -> [Int] {
        var table = source
        let value = table[center]
        let radius = 100 - detail
        let lower = center - radius, upper = center + radius
        let start = max(0, lower), end = min(256, upper)
        if start < end { for i in start..<end { table[i] = value } }
        let left = max(0, lower - 30)
        if left < lower {
            let edge = table[left]
            for i in stride(from: lower, to: left, by: -1) {
                table[i] = value + (lower - i) * (edge - value) / (lower - left)
            }
        }
        let right = min(255, upper + 30)
        if upper < right {
            let edge = table[right]
            for i in upper..<right {
                table[i] = value + (i - upper) * (edge - value) / (right - upper)
            }
        }
        return table
    }
}
