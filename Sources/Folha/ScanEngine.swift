import Foundation
import UIKit
import CoreImage
import Vision
import CoreText

enum ScanEngine {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    // Synchronous worker APIs: callers must schedule image/OCR/PDF work off the
    // UI actor. Never dispatch synchronously to the main queue for UIKit drawing.
    // This lock also serializes read-modify-publish operations in this process.
    private static let manifestLock = NSRecursiveLock()

    private static func transaction<T>(_ work: () throws -> T) rethrows -> T {
        manifestLock.lock()
        defer { manifestLock.unlock() }
        return try work()
    }

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
                guard [corners.topLeft, corners.topRight, corners.bottomLeft, corners.bottomRight]
                    .allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
                    throw ScanFailure.message("Coordenadas de recorte invalidas.")
                }
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
        // Independent APPROXIMATIONS, not byte-for-byte recovered native modes.
        // Only the selector IDs/order are recovered. No claim of visual parity.
        switch page.filter {
        case .natural: break
        case .clean:
            current = current.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.14, kCIInputBrightnessKey: 0.02])
            current = current.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.35])
        case .grayscale:
            current = current.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
        case .document:
            current = current.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 1.6, kCIInputBrightnessKey: 0.04])
            current = current.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.55])
        case .lighten:
            current = current.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.45])
        case .blackAndWhite2:
            current = removingShadows(current)
            current = current.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
            current = current.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.75])
        case .removeShadow:
            current = removingShadows(current)
        }
        let extent = current.extent
        guard !extent.isNull, !extent.isInfinite, extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else {
            throw ScanFailure.message("Dimensoes de processamento invalidas.")
        }
        // Perspective correction can expand the image beyond the input budget.
        let ratio = min(1, ScanConfiguration.maximumWorkingDimension / max(extent.width, extent.height))
        if ratio < 1 {
            current = current.transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
        }
        guard let rendered = context.createCGImage(current, from: current.extent.integral) else {
            throw ScanFailure.message("Falha ao renderizar a pagina.")
        }
        page.width = rendered.width
        page.height = rendered.height
        return UIImage(cgImage: rendered)
    }

    private static func removingShadows(_ image: CIImage) -> CIImage {
        // Independent local-illumination estimate; this is not a recovered kernel.
        let radius = max(4, min(80, max(image.extent.width, image.extent.height) * 0.025))
        let background = image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: image.extent)
        return background.applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: image])
            .cropped(to: image.extent)
    }

    private static func overlayBounds(_ overlay: PageOverlay) throws -> CGRect {
        let values = [overlay.x, overlay.y, overlay.width, overlay.height,
                      overlay.x + overlay.width, overlay.y + overlay.height]
        guard values.allSatisfy({ $0.isFinite }), overlay.width > 0, overlay.height > 0 else {
            throw ScanFailure.message("Limites da anotacao invalidos.")
        }
        let left = max(0, overlay.x), top = max(0, overlay.y)
        let right = min(1, overlay.x + overlay.width), bottom = min(1, overlay.y + overlay.height)
        guard right > left, bottom > top else {
            // Fail closed, especially for redactions: never silently omit a mask.
            throw ScanFailure.message("A anotacao esta fora da pagina.")
        }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    static func renderOverlays(_ image: UIImage, overlays: [PageOverlay]) throws -> UIImage {
        guard !overlays.isEmpty else { return image }
        guard let pixels = image.cgImage, pixels.width > 0, pixels.height > 0,
              pixels.width <= 3202, pixels.height <= 3202, overlays.count <= 512 else {
            throw ScanFailure.message("Limite de imagem ou anotacoes excedido.")
        }
        var totalPoints = 0
        for overlay in overlays {
            guard overlay.points.count <= 20_000 else { throw ScanFailure.message("Traco muito longo.") }
            totalPoints += overlay.points.count
            guard totalPoints <= 100_000, (overlay.text?.utf16.count ?? 0) <= 10_000 else {
                throw ScanFailure.message("Limite de conteudo das anotacoes excedido.")
            }
            if overlay.kind == .ink {
                guard overlay.lineWidth.isFinite, overlay.lineWidth > 0,
                      overlay.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                    throw ScanFailure.message("Coordenadas do traco invalidas.")
                }
            } else {
                _ = try overlayBounds(overlay)
            }
        }
        let size = CGSize(width: pixels.width, height: pixels.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        // A private renderer owns its context on the calling worker, not a view.
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
            func pixelsRect(_ overlay: PageOverlay) -> CGRect {
                // Validated before entering this nonthrowing drawing closure.
                let left = max(0, overlay.x), top = max(0, overlay.y)
                let right = min(1, overlay.x + overlay.width), bottom = min(1, overlay.y + overlay.height)
                return CGRect(x: left * size.width, y: top * size.height,
                              width: (right - left) * size.width, height: (bottom - top) * size.height)
            }
            for overlay in overlays where overlay.kind != .redaction {
                context.saveGState()
                context.setFillColor(UIColor.black.cgColor)
                context.setStrokeColor(UIColor.black.cgColor)
                if overlay.kind == .text, let text = overlay.text, !text.isEmpty {
                    let rect = pixelsRect(overlay)
                    context.clip(to: rect)
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: min(64, max(6, rect.height * 0.65))),
                        .foregroundColor: UIColor.black
                    ]
                    (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
                                           attributes: attributes, context: nil)
                } else if overlay.kind == .ink, let first = overlay.points.first {
                    func point(_ item: UnitPointRecord) -> CGPoint {
                        CGPoint(x: min(1, max(0, item.x)) * size.width,
                                y: min(1, max(0, item.y)) * size.height)
                    }
                    let width = max(1, min(0.1, overlay.lineWidth) * min(size.width, size.height))
                    context.clip(to: CGRect(origin: .zero, size: size))
                    context.setLineWidth(width)
                    context.setLineCap(.round)
                    context.setLineJoin(.round)
                    if overlay.points.count == 1 {
                        let start = point(first)
                        context.fillEllipse(in: CGRect(x: start.x - width / 2, y: start.y - width / 2, width: width, height: width))
                    } else {
                        context.beginPath()
                        context.move(to: point(first))
                        for item in overlay.points.dropFirst() { context.addLine(to: point(item)) }
                        context.strokePath()
                    }
                }
                context.restoreGState()
            }
            // Redactions always win, even if text/ink appears later in the array.
            context.setBlendMode(.copy)
            context.setAlpha(1)
            context.setShouldAntialias(false)
            context.setFillColor(UIColor.black.cgColor)
            for overlay in overlays where overlay.kind == .redaction {
                context.fill(pixelsRect(overlay).integral)
            }
        }
    }

    private static func visibleLines(_ lines: [OCRLine], page: ScanPage) throws -> [OCRLine] {
        let masks = try (page.overlays ?? []).filter { $0.kind == .redaction }.map { try overlayBounds($0) }
        return lines.filter { line in
            guard [line.x, line.y, line.width, line.height].allSatisfy({ $0.isFinite }),
                  line.width > 0, line.height > 0 else { return false }
            // OCR is bottom-left; overlays are top-left. Discard the whole line
            // when it straddles a mask rather than guessing which words survived.
            let box = CGRect(x: line.x, y: 1 - line.y - line.height, width: line.width, height: line.height)
            return !masks.contains { $0.intersects(box) }
        }
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
        try transaction {
            try validate(document)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(document).write(to: folder.appendingPathComponent("document.json"), options: .atomic)
        }
    }

    private static func validate(_ document: ScanDocument) throws {
        guard Set(document.pages.map(\.id)).count == document.pages.count else {
            throw ScanFailure.message("O documento contem IDs de pagina duplicados.")
        }
        for page in document.pages {
            for name in [page.sourceFile, page.renderedFile, page.thumbnailFile] {
                guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
                    throw ScanFailure.message("Nome de arquivo da pagina invalido.")
                }
            }
        }
    }

    private static func currentDocument(_ requested: ScanDocument, folder: URL) throws -> ScanDocument {
        try validate(requested)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let current = try decoder.decode(ScanDocument.self, from: Data(contentsOf: folder.appendingPathComponent("document.json")))
        guard current.id == requested.id else { throw ScanFailure.message("Manifest de outro documento.") }
        try validate(current)
        // Disk is authoritative: do not resurrect deleted pages, undo a reorder,
        // or drop concurrently appended pages from an older caller snapshot.
        return current
    }

    private static func stagingFolder(in folder: URL) throws -> URL {
        let staging = folder.appendingPathComponent(".pending-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return staging
    }

    private static func makePage(_ input: ScanInput, id: UUID = UUID(), replacing previous: ScanPage? = nil,
                                 folder: URL) throws -> ScanPage {
        try autoreleasepool {
            let data = try input.bytes()
            var page = ScanPage(id: id, sourceFile: "\(id.uuidString)-\(UUID().uuidString).source",
                                renderedFile: "", thumbnailFile: "", autoCrop: input.autoCrop)
            // A new capture invalidates geometry, overlays and OCR, but not the
            // user's selected appearance. Keep every historical source intact.
            if let previous = previous {
                page.filter = previous.filter
                page.reconstructedAdjustments = previous.reconstructedAdjustments
            }
            try data.write(to: folder.appendingPathComponent(page.sourceFile), options: .atomic)
            let rendered = try process(image(data), page: &page)
            try writeRendered(rendered, page: &page, folder: folder)
            return page
        }
    }

    private static func publish(_ document: ScanDocument, stagedPages: [ScanPage], staging: URL, folder: URL) throws {
        for page in stagedPages {
            for name in [page.sourceFile, page.renderedFile, page.thumbnailFile] {
                try FileManager.default.moveItem(at: staging.appendingPathComponent(name), to: folder.appendingPathComponent(name))
            }
        }
        // This is the only commit point. On failure the previous manifest and
        // its referenced files remain usable; unpublished sources are retained.
        try writeManifest(document, folder: folder)
        try? FileManager.default.removeItem(at: staging) // now empty
    }

    private static func writeRendered(_ image: UIImage, page: inout ScanPage, folder: URL) throws {
        let revision = UUID().uuidString
        let masks = (page.overlays ?? []).filter { $0.kind == .redaction }
        let redacted = !masks.isEmpty
        let suffix = redacted ? "png" : "jpg"
        page.renderedFile = "\(page.id.uuidString)-\(revision).\(suffix)"
        page.thumbnailFile = "\(page.id.uuidString)-\(revision)-thumb.\(suffix)"
        let thumbnail = try renderOverlays(normalized(image, maximum: ScanConfiguration.thumbnailDimension), overlays: masks)
        // Lossless masks avoid JPEG ringing; reapply masks after downsampling.
        let renderedData = redacted ? image.pngData() : image.jpegData(compressionQuality: ScanConfiguration.workingJPEGQuality)
        let thumbnailData = redacted ? thumbnail.pngData() : thumbnail.jpegData(compressionQuality: 0.8)
        guard let renderedData = renderedData, let thumbnailData = thumbnailData else {
            throw ScanFailure.message("Falha ao guardar a pagina processada.")
        }
        try renderedData.write(to: folder.appendingPathComponent(page.renderedFile), options: .atomic)
        try thumbnailData.write(to: folder.appendingPathComponent(page.thumbnailFile), options: .atomic)
        // Never fall back to the previous OCR, including on recognition failure.
        page.lines = []
        do {
            page.lines = try visibleLines(recognize(image), page: page)
            page.ocrWarning = nil
        } catch {
            page.lines = []
            page.ocrWarning = "OCR nao concluido: \(error.localizedDescription)"
        }
    }

    static func create(inputs: [ScanInput], root: URL) throws -> ScanDocument {
        try transaction {
            guard !inputs.isEmpty else { throw ScanFailure.message("Nenhuma pagina foi recebida.") }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "pt_BR")
            formatter.dateFormat = "dd-MM-yyyy HH.mm"
            var document = ScanDocument(title: "Documento \(formatter.string(from: Date()))")
            let staging = try stagingFolder(in: root)
            for input in inputs {
                document.pages.append(try makePage(input, folder: staging))
            }
            try writeManifest(document, folder: staging)
            try FileManager.default.moveItem(at: staging, to: root.appendingPathComponent(document.id.uuidString, isDirectory: true))
            return document
        }
    }

    static func append(inputs: [ScanInput], to document: ScanDocument, root: URL) throws -> ScanDocument {
        try transaction {
            let folder = root.appendingPathComponent(document.id.uuidString, isDirectory: true)
            var current = try currentDocument(document, folder: folder)
            guard !inputs.isEmpty else { return current }
            let staging = try stagingFolder(in: folder)
            var added: [ScanPage] = []
            for input in inputs { added.append(try makePage(input, folder: staging)) }
            current.pages.append(contentsOf: added)
            current.updatedAt = Date()
            try publish(current, stagedPages: added, staging: staging, folder: folder)
            return current
        }
    }

    static func replace(input: ScanInput, in document: ScanDocument, pageID: UUID, root: URL) throws -> ScanDocument {
        try transaction {
            let folder = root.appendingPathComponent(document.id.uuidString, isDirectory: true)
            var current = try currentDocument(document, folder: folder)
            guard let index = current.pages.firstIndex(where: { $0.id == pageID }) else {
                throw ScanFailure.message("Pagina nao encontrada.")
            }
            let staging = try stagingFolder(in: folder)
            let page = try makePage(input, id: pageID, replacing: current.pages[index], folder: staging)
            current.pages[index] = page
            current.updatedAt = Date()
            try publish(current, stagedPages: [page], staging: staging, folder: folder)
            return current
        }
    }

    static func revise(document: ScanDocument, page changed: ScanPage, root: URL) throws -> ScanDocument {
        try transaction {
            let folder = root.appendingPathComponent(document.id.uuidString, isDirectory: true)
            var current = try currentDocument(document, folder: folder)
            guard let index = current.pages.firstIndex(where: { $0.id == changed.id }) else {
                throw ScanFailure.message("Pagina nao encontrada.")
            }
            let previous = current.pages[index]
            guard changed.sourceFile == previous.sourceFile else {
                throw ScanFailure.message("A fonte da pagina mudou; atualize o editor antes de salvar.")
            }
            var page = changed
            let data = try Data(contentsOf: folder.appendingPathComponent(previous.sourceFile))
            let rendered = try process(image(data), page: &page)
            try writeRendered(rendered, page: &page, folder: folder)
            current.pages[index] = page
            current.updatedAt = Date()
            try writeManifest(current, folder: folder)
            // Keep immutable prior derivatives too: other readers may hold an
            // older snapshot. Reclamation requires a separate coordinated job.
            return current
        }
    }

    static func fit(_ source: CGSize, inside bounds: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let ratio = min(bounds.width / source.width, bounds.height / source.height)
        let size = CGSize(width: source.width * ratio, height: source.height * ratio)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    static func exportPDF(document: ScanDocument, root: URL, searchable: Bool) throws -> URL {
        guard !document.pages.isEmpty else { throw ScanFailure.message("O documento esta vazio.") }
        try validate(document)
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
                        let stored = try image(Data(contentsOf: folder.appendingPathComponent(page.renderedFile)))
                        let masks = (page.overlays ?? []).filter { $0.kind == .redaction }
                        let image = try renderOverlays(stored, overlays: masks)
                        pdf.beginPage()
                        let frame = fit(image.size, inside: content)
                        image.draw(in: frame)
                        if searchable {
                            // Redacted exports must not trust cached OCR, even
                            // if the caller hands us a stale or edited snapshot.
                            let lines = masks.isEmpty ? page.lines : ((try? visibleLines(recognize(image), page: page)) ?? [])
                            drawText(lines, frame: frame, context: pdf.cgContext, pageHeight: bounds.height)
                        }
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
        let adjusted: UIImage
        if let settings = page.reconstructedAdjustments {
            adjusted = try RecoveredPixelImage.apply(base, settings: settings)
        } else {
            adjusted = base
        }
        // Overlay coordinates refer to the processed image, not the source.
        // All persistence/OCR/thumbnail/export paths consume these raster pixels.
        return try renderOverlays(adjusted, overlays: page.overlays ?? [])
    }

    static func recoveredPreview(source: UIImage, page: inout ScanPage) throws -> UIImage {
        try process(source, page: &page)
    }
}
