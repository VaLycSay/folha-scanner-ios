import Foundation
import UIKit
import CoreImage
import Vision
import CoreText

enum ScanEngine {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func image(_ data: Data) throws -> UIImage {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw ScanFailure.message("A imagem nao pode ser lida.")
        }
        return image
    }

    static func normalized(_ image: UIImage, maximum: CGFloat) -> UIImage {
        let source = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let ratio = min(1, maximum / max(source.width, source.height))
        let size = CGSize(width: max(1, floor(source.width * ratio)), height: max(1, floor(source.height * ratio)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor.white.setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    static func detectCorners(_ image: CGImage) throws -> PageCorners? {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1
        request.minimumConfidence = 0.6
        request.minimumSize = 0.2
        request.minimumAspectRatio = 0.2
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let rectangle = request.results?.first else { return nil }
        return PageCorners(topLeft: .init(rectangle.topLeft), topRight: .init(rectangle.topRight),
                           bottomLeft: .init(rectangle.bottomLeft), bottomRight: .init(rectangle.bottomRight))
    }

    static func processBase(_ source: UIImage, page: inout ScanPage) throws -> UIImage {
        let normalized = normalized(source, maximum: ScanConfiguration.maximumWorkingDimension)
        guard let cg = normalized.cgImage else { throw ScanFailure.message("Imagem sem pixels utilizaveis.") }
        var current = CIImage(cgImage: cg)
        if page.autoCrop {
            if page.corners == nil { page.corners = try detectCorners(cg) }
            if let corners = page.corners {
                let extent = current.extent
                func vector(_ point: UnitPointRecord) -> CIVector {
                    CIVector(x: extent.minX + CGFloat(point.x) * extent.width,
                             y: extent.minY + CGFloat(point.y) * extent.height)
                }
                guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
                    throw ScanFailure.message("Correcao de perspectiva indisponivel.")
                }
                filter.setValue(current, forKey: kCIInputImageKey)
                filter.setValue(vector(corners.topLeft), forKey: "inputTopLeft")
                filter.setValue(vector(corners.topRight), forKey: "inputTopRight")
                filter.setValue(vector(corners.bottomLeft), forKey: "inputBottomLeft")
                filter.setValue(vector(corners.bottomRight), forKey: "inputBottomRight")
                guard let corrected = filter.outputImage else {
                    throw ScanFailure.message("Nao foi possivel aplicar o recorte.")
                }
                current = corrected
            }
        }
        if page.quarterTurns % 4 != 0 {
            current = current.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(page.quarterTurns % 4) * .pi / 2))
        }
        // Independent Core Image filters; not the proprietary enhancement engine.
        switch page.filter {
        case .natural: break
        case .clean:
            current = current.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.14, kCIInputBrightnessKey: 0.02])
            current = current.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.35])
        case .grayscale:
            current = current.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
        case .document:
            current = current.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 1.6, kCIInputBrightnessKey: 0.04])
        }
        guard let rendered = context.createCGImage(current, from: current.extent.integral) else {
            throw ScanFailure.message("Falha ao renderizar a pagina.")
        }
        page.width = rendered.width
        page.height = rendered.height
        return UIImage(cgImage: rendered)
    }

    static func recognize(_ image: UIImage) throws -> [OCRLine] {
        guard let cg = image.cgImage else { throw ScanFailure.message("OCR sem imagem utilizavel.") }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let available = try request.supportedRecognitionLanguages()
        let languages = ScanConfiguration.preferredOCRLanguages.filter { available.contains($0) }
        if !languages.isEmpty { request.recognitionLanguages = languages }
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return OCRLine(text: candidate.string, confidence: candidate.confidence,
                           x: box.minX, y: box.minY, width: box.width, height: box.height)
        }
    }

    static func writeManifest(_ document: ScanDocument, folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: folder.appendingPathComponent("document.json"), options: .atomic)
    }

    private static func writeRendered(_ image: UIImage, page: inout ScanPage, folder: URL) throws {
        let revision = UUID().uuidString
        page.renderedFile = "\(page.id.uuidString)-\(revision).jpg"
        page.thumbnailFile = "\(page.id.uuidString)-\(revision)-thumb.jpg"
        guard let jpeg = image.jpegData(compressionQuality: ScanConfiguration.workingJPEGQuality),
              let thumb = normalized(image, maximum: ScanConfiguration.thumbnailDimension).jpegData(compressionQuality: 0.8) else {
            throw ScanFailure.message("Falha ao guardar a pagina processada.")
        }
        try jpeg.write(to: folder.appendingPathComponent(page.renderedFile), options: .atomic)
        try thumb.write(to: folder.appendingPathComponent(page.thumbnailFile), options: .atomic)
        do {
            page.lines = try recognize(image)
            page.ocrWarning = nil
        } catch {
            page.lines = []
            page.ocrWarning = "OCR nao concluido: \(error.localizedDescription)"
        }
    }

    static func create(inputs: [ScanInput], root: URL) throws -> ScanDocument {
        guard !inputs.isEmpty else { throw ScanFailure.message("Nenhuma pagina foi recebida.") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "dd-MM-yyyy HH.mm"
        var document = ScanDocument(title: "Documento \(formatter.string(from: Date()))")
        let staging = root.appendingPathComponent(".pending-\(document.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        for input in inputs {
            let page: ScanPage = try autoreleasepool {
                let data = try input.bytes()
                let id = UUID()
                var page = ScanPage(id: id, sourceFile: "\(id.uuidString).source", renderedFile: "", thumbnailFile: "", autoCrop: input.autoCrop)
                try data.write(to: staging.appendingPathComponent(page.sourceFile), options: .atomic)
                let rendered = try process(image(data), page: &page)
                try writeRendered(rendered, page: &page, folder: staging)
                return page
            }
            document.pages.append(page)
        }
        try writeManifest(document, folder: staging)
        try FileManager.default.moveItem(at: staging, to: root.appendingPathComponent(document.id.uuidString, isDirectory: true))
        return document
    }

    static func revise(document: ScanDocument, page changed: ScanPage, root: URL) throws -> ScanDocument {
        var document = document
        guard let index = document.pages.firstIndex(where: { $0.id == changed.id }) else {
            throw ScanFailure.message("Pagina nao encontrada.")
        }
        let folder = root.appendingPathComponent(document.id.uuidString, isDirectory: true)
        let previous = document.pages[index]
        var page = changed
        let data = try Data(contentsOf: folder.appendingPathComponent(page.sourceFile))
        let rendered = try process(image(data), page: &page)
        try writeRendered(rendered, page: &page, folder: folder)
        document.pages[index] = page
        document.updatedAt = Date()
        try writeManifest(document, folder: folder)
        // Only obsolete derivatives generated by this app; keep the source.
        for filename in [previous.renderedFile, previous.thumbnailFile] where !filename.isEmpty && filename != page.sourceFile {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(filename))
        }
        return document
    }

    static func fit(_ source: CGSize, inside bounds: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let ratio = min(bounds.width / source.width, bounds.height / source.height)
        let size = CGSize(width: source.width * ratio, height: source.height * ratio)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    static func exportPDF(document: ScanDocument, root: URL, searchable: Bool) throws -> URL {
        guard !document.pages.isEmpty else { throw ScanFailure.message("O documento esta vazio.") }
        let folder = root.appendingPathComponent(document.id.uuidString, isDirectory: true)
        // Fail before publishing if any page is missing; never silently omit one.
        for page in document.pages {
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(page.renderedFile).path) else {
                throw ScanFailure.message("Uma pagina nao esta disponivel. O PDF nao foi gerado.")
            }
        }
        let bounds = CGRect(origin: .zero, size: ScanConfiguration.pageSize)
        let content = bounds.insetBy(dx: ScanConfiguration.pageMargin, dy: ScanConfiguration.pageMargin)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: document.title, kCGPDFContextCreator as String: "Folha"]
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        var renderFailure: Error?
        let data = renderer.pdfData { pdf in
            for page in document.pages {
                autoreleasepool {
                    do {
                        let image = try image(Data(contentsOf: folder.appendingPathComponent(page.renderedFile)))
                        pdf.beginPage()
                        let frame = fit(image.size, inside: content)
                        image.draw(in: frame)
                        if searchable { drawText(page.lines, frame: frame, context: pdf.cgContext, pageHeight: bounds.height) }
                    } catch { renderFailure = error }
                }
                if renderFailure != nil { break }
            }
        }
        if let failure = renderFailure { throw failure }
        let exports = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let url = exports.appendingPathComponent(exportFileName(title: document.title, id: document.id))
        try data.write(to: url, options: .atomic)
        return url
    }

    static func exportFileName(title: String, id: UUID) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let scalars = title.unicodeScalars.filter { allowed.contains($0) }
        let clean = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = clean.isEmpty ? "Documento" : String(clean.prefix(60))
        // Preview and sharing of one document reuse its own generated export.
        return "\(prefix)-\(id.uuidString).pdf"
    }

    private static func drawText(_ lines: [OCRLine], frame: CGRect, context: CGContext, pageHeight: CGFloat) {
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: 0, y: pageHeight)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.setTextDrawingMode(.invisible)
        for item in lines where !item.text.isEmpty {
            let box = item.bounds
            let height = max(1, box.height * frame.height)
            let font = CTFontCreateWithName("Helvetica" as CFString, height * 0.8, nil)
            let attributed = NSAttributedString(string: item.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            guard width > 0, box.width > 0 else { continue }
            context.saveGState()
            context.translateBy(x: frame.minX + box.minX * frame.width,
                                y: pageHeight - frame.maxY + box.minY * frame.height)
            context.scaleBy(x: box.width * frame.width / width, y: 1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }
}

extension ScanEngine {
    static let recoveredManifestName = "document.json"

    static func process(_ source: UIImage, page: inout ScanPage) throws -> UIImage {
        let base = try processBase(source, page: &page)
        guard let settings = page.reconstructedAdjustments else { return base }
        return try RecoveredPixelImage.apply(base, settings: settings)
    }

    static func recoveredPreview(source: UIImage, page: inout ScanPage) throws -> UIImage {
        try process(source, page: &page)
    }
}