import UIKit

enum RecoveredPixelImage {
    static func apply(_ image: UIImage, settings: ReconstructedAdjustmentContract) throws -> UIImage {
        guard let input = image.cgImage else { throw ScanFailure.message("Imagem sem pixels legiveis.") }
        let width = input.width, height = input.height
        guard width <= 16_384, height <= 16_384 else { throw ScanFailure.message("Imagem muito grande.") }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let flags = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: flags) else { return false }
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(input, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { throw ScanFailure.message("Nao foi possivel preparar os pixels.") }
        let output = try RecoveredPixelAdjustment.applyRGBA(bytes, width: width, height: height, settings: settings)
        guard let provider = CGDataProvider(data: Data(output) as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: flags),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw ScanFailure.message("Nao foi possivel criar a imagem ajustada.")
        }
        return UIImage(cgImage: cg)
    }
}
