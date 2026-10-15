import Foundation

struct PixelFixture: Decodable {
    let fixture: String
    let width: Int
    let height: Int
    let brightness: Int32
    let contrast: Int32
    let detail: Int32
    let rgba: String
    let expected: String
}

@main struct CompareRecoveredPixels {
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixtures = try JSONDecoder().decode([PixelFixture].self, from: Data(contentsOf: url))
        var mismatches = 0
        for fixture in fixtures {
            guard let pixels = Data(base64Encoded: fixture.rgba), let expected = Data(base64Encoded: fixture.expected) else {
                throw NSError(domain: "Fixture", code: 1)
            }
            let result = try RecoveredPixelAdjustment.applyRGBA(Array(pixels), width: fixture.width,
                height: fixture.height, settings: ReconstructedAdjustmentContract(brightness: fixture.brightness,
                    contrast: fixture.contrast, detail: fixture.detail))
            if Data(result) != expected { mismatches += 1; print("Mismatch: \(fixture.fixture) \(fixture.brightness),\(fixture.contrast),\(fixture.detail)") }
        }
        print("Recovered RGBA fixtures: \(fixtures.count); mismatches: \(mismatches)")
        if mismatches != 0 { throw NSError(domain: "RecoveredPixelComparison", code: mismatches) }
    }
}
