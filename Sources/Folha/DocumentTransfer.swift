import Foundation
import UIKit
import CoreGraphics
import CoreText
import ImageIO
import PDFKit

/// Independent, local-only import/export. No PDF actions, JavaScript, web views,
/// document converters, or original-image fallback are used here.
enum DocumentTransfer {
    static let maximumImportPages = 50
    static let maximumFileBytes = 64 * 1024 * 1024
    static let maximumImportedJPEGBytes = 128 * 1024 * 1024
    private static let maximumSourcePixels: Double = 100_000_000

    enum Failure: LocalizedError, Equatable {
        case localFileRequired
        case fileMissing(String)
        case unreadableFile(String)
        case emptyFile
        case fileTooLarge
        case invalidPDF
        case passwordRequired
        case emptyPDF
        case tooManyPages(Int)
        case invalidPDFPage(Int)
        case unsafePDFBounds(Int)
        case invalidImage
        case unsafeImageSize
        case encodingFailed(Int)
        case importBudgetExceeded
        case emptyDocument
        case emptyBatch
        case duplicatePages
        case unsafePageFile(Int)
        case originalInsteadOfRendered(Int)
        case renderedPageMissing(Int, String)
        case renderedPageUnreadable(Int, String)
        case pageExportFailed(Int, String)

        var errorDescription: String? {
            switch self {
            case .localFileRequired: return "Selecione um arquivo local, nao um endereco de rede."
            case .fileMissing(let name): return "Arquivo nao encontrado: \(name)."
            case .unreadableFile(let name): return "Nao foi possivel ler o arquivo: \(name)."
            case .emptyFile: return "O arquivo esta vazio."
            case .fileTooLarge: return "O arquivo excede o limite seguro de 64 MiB."
            case .invalidPDF: return "O PDF e invalido ou esta danificado."
            case .passwordRequired: return "O PDF esta criptografado e exige senha. Importe uma copia desbloqueada."
            case .emptyPDF: return "O PDF nao contem paginas."
            case .tooManyPages(let count): return "O PDF tem \(count) paginas; o limite e 50."
            case .invalidPDFPage(let page): return "Nao foi possivel ler a pagina \(page) do PDF."
            case .unsafePDFBounds(let page): return "A pagina \(page) do PDF tem limites ou rotacao invalidos."
            case .invalidImage: return "O arquivo nao e uma imagem local compativel ou esta danificado."
            case .unsafeImageSize: return "A imagem excede os limites seguros de dimensoes ou pixels."
            case .encodingFailed(let page): return "Nao foi possivel codificar a pagina \(page) como JPEG."
            case .importBudgetExceeded: return "As paginas importadas excedem o limite de 128 MiB de JPEG."
            case .emptyDocument: return "O documento nao contem paginas para exportar."
            case .emptyBatch: return "Nenhum documento foi selecionado para exportar."
            case .duplicatePages: return "O documento contem IDs de pagina duplicados."
            case .unsafePageFile(let page): return "O caminho da pagina \(page) nao e seguro."
            case .originalInsteadOfRendered(let page):
                return "A pagina \(page) aponta para um original ou miniatura, nao para a imagem renderizada."
            case .renderedPageMissing(let page, let name):
                return "A imagem renderizada da pagina \(page) esta ausente: \(name). Nenhum original sera usado."
            case .renderedPageUnreadable(let page, let name):
                return "A imagem renderizada da pagina \(page) nao pode ser lida: \(name)."
            case .pageExportFailed(let page, let reason): return "Falha ao exportar a pagina \(page): \(reason)"
            }
        }
    }

    static func importFile(_ url: URL) async throws -> [ScanInput] {
        try await offMain {
            guard url.isFileURL else { throw Failure.localFileRequired }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // Keep the security scope alive until ALL decoding/rendering is done.
            let data = try readFile(url)
            let pdfHeader = data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil
            if pdfHeader || url.pathExtension.lowercased() == "pdf" {
                return try importPDF(data)
            }
            return try autoreleasepool {
                let image = try decodedImage(data)
                guard let jpeg = image.jpegData(compressionQuality: ScanConfiguration.workingJPEGQuality) else {
                    throw Failure.encodingFailed(1)
                }
                return [.photo(jpeg)]
            }
        }
    }

    static func exportImages(document: ScanDocument, root: URL) async throws -> [URL] {
        try await offMain {
            let files = try renderedFiles(document: document, root: root)
            return try withExportDirectory { directory in
                var result: [URL] = []
                for (index, page) in document.pages.enumerated() {
                    try Task.checkCancellation()
                    let output = directory.appendingPathComponent(fileName(document, index: index, suffix: "jpg"))
                    try autoreleasepool {
                        do {
                            // Engine.process already bakes text and ink into renderedFile.
                            // Reapplying them would draw annotations twice. Masks alone are
                            // reapplied AFTER resizing, including for a stale derivative.
                            let stored = try decodedImage(readFile(files[index]))
                            let masks = (page.overlays ?? []).filter { $0.kind == .redaction }
                            let protected = try ScanEngine.renderOverlays(stored, overlays: masks)
                            guard let jpeg = protected.jpegData(compressionQuality: ScanConfiguration.workingJPEGQuality) else {
                                throw Failure.encodingFailed(index + 1)
                            }
                            try jpeg.write(to: output, options: .atomic)
                        } catch {
                            throw Failure.pageExportFailed(index + 1, error.localizedDescription)
                        }
                    }
                    result.append(output)
                }
                return result
            }
        }
    }

    /// Shared by the UI and text export. Pure: no files, OCR, actors or mutation.
    /// OCR bounds use Vision's bottom-left origin; overlays use top-left.
    /// Unsafe geometry on a redacted page suppresses that page's ENTIRE OCR.
    /// Otherwise, discard whole lines touching a mask, not just selected words.
    static func visibleText(document: ScanDocument) -> String {
        document.pages.map { visiblePageText($0) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func exportText(document: ScanDocument, root: URL) async throws -> URL {
        try await offMain {
            _ = try renderedFiles(document: document, root: root)
            return try withExportDirectory { directory in
                let output = directory.appendingPathComponent(fileName(document, index: nil, suffix: "txt"))
                try Data(visibleText(document: document).utf8).write(to: output, options: .atomic)
                return output
            }
        }
    }

    static func exportWord(document: ScanDocument, root: URL) async throws -> URL {
        try await offMain {
            _ = try renderedFiles(document: document, root: root)
            return try withExportDirectory { directory in
                let output = directory.appendingPathComponent(fileName(document, index: nil, suffix: "doc"))
                func escapeHTML(_ text: String) -> String {
                    text.replacingOccurrences(of: "&", with: "&amp;")
                        .replacingOccurrences(of: "<", with: "&lt;")
                        .replacingOccurrences(of: ">", with: "&gt;")
                }
                var body = "<html><head><meta charset=\"utf-8\"><title>\(escapeHTML(document.title))</title>"
                body += "<style>body{font-family:-apple-system,Calibri,Arial,sans-serif;margin:32pt;line-height:1.45;}h1{color:#111214;font-size:18pt;}h2{color:#17C99B;font-size:12pt;margin-top:20pt;}p{font-size:11pt;margin:4pt 0;}</style></head><body>"
                body += "<h1>\(escapeHTML(document.title))</h1>"
                for (index, page) in document.pages.enumerated() {
                    body += "<h2>Página \(index + 1)</h2>"
                    let lines = visiblePageLines(page)
                    if lines.isEmpty {
                        body += "<p><em>(Sem texto reconhecido nesta página)</em></p>"
                    } else {
                        for line in lines {
                            body += "<p>\(escapeHTML(line.text))</p>"
                        }
                    }
                }
                body += "</body></html>"
                try Data(body.utf8).write(to: output, options: .atomic)
                return output
            }
        }
    }

    static func exportExcelCSV(document: ScanDocument, root: URL) async throws -> URL {
        try await offMain {
            _ = try renderedFiles(document: document, root: root)
            return try withExportDirectory { directory in
                let output = directory.appendingPathComponent(fileName(document, index: nil, suffix: "csv"))
                func csvCell(_ value: String) -> String {
                    let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
                    return "\"\(escaped)\""
                }
                var rows: [String] = ["\"Pagina\",\"Coluna 1\",\"Coluna 2\",\"Coluna 3\",\"Coluna 4\""]
                for (pageIndex, page) in document.pages.enumerated() {
                    let sortedTopDown = visiblePageLines(page).sorted { a, b in
                        let topA = 1.0 - a.y - a.height
                        let topB = 1.0 - b.y - b.height
                        if abs(topA - topB) > 0.022 { return topA < topB }
                        return a.x < b.x
                    }
                    var currentRow: [OCRLine] = []
                    var currentTop: Double?
                    for item in sortedTopDown {
                        let top = 1.0 - item.y - item.height
                        if let ref = currentTop, abs(top - ref) <= 0.022 {
                            currentRow.append(item)
                        } else {
                            if !currentRow.isEmpty {
                                let cols = currentRow.sorted { $0.x < $1.x }.map { csvCell($0.text) }
                                rows.append((["\"\(pageIndex + 1)\""] + cols).joined(separator: ","))
                            }
                            currentRow = [item]
                            currentTop = top
                        }
                    }
                    if !currentRow.isEmpty {
                        let cols = currentRow.sorted { $0.x < $1.x }.map { csvCell($0.text) }
                        rows.append((["\"\(pageIndex + 1)\""] + cols).joined(separator: ","))
                    }
                }
                let content = "\u{FEFF}" + rows.joined(separator: "\r\n")
                try Data(content.utf8).write(to: output, options: .atomic)
                return output
            }
        }
    }

    enum PDFPageSize: String, CaseIterable, Identifiable, Sendable {
        case a4 = "A4"
        case original = "Tamanho original"
        case letter = "Carta (Letter)"
        case legal = "Oficio (Legal)"

        var id: String { rawValue }

        var pointsSize: CGSize? {
            switch self {
            case .a4: return CGSize(width: 595, height: 842)
            case .original: return nil
            case .letter: return CGSize(width: 612, height: 792)
            case .legal: return CGSize(width: 612, height: 1008)
            }
        }
    }

    enum PDFPageOrientation: String, CaseIterable, Identifiable, Sendable {
        case auto = "Auto"
        case portrait = "Retrato"
        case landscape = "Paisagem"

        var id: String { rawValue }
    }

    static func exportPDFs(documents: [ScanDocument], root: URL, searchable: Bool) async throws -> [URL] {
        try await offMain {
            guard !documents.isEmpty else { throw Failure.emptyBatch }
            // Preflight the complete batch. A late engine/I/O error still throws,
            // never returning an array containing only the successful prefix.
            for document in documents {
                try Task.checkCancellation()
                _ = try renderedFiles(document: document, root: root)
            }
            return try withExportDirectory { directory in
                var result: [URL] = []
                for (index, document) in documents.enumerated() {
                    try Task.checkCancellation()
                    let output = directory.appendingPathComponent(fileName(document, index: index, suffix: "pdf"))
                    try autoreleasepool {
                        var exporting = document
                        // Also bound the filename generated internally by the engine;
                        // a 60-character Unicode title can exceed filesystem byte limits.
                        exporting.title = safeTitle(document.title)
                        let generated = try ScanEngine.exportPDF(document: exporting, root: root, searchable: searchable)
                        try Task.checkCancellation()
                        try FileManager.default.copyItem(at: generated, to: output)
                    }
                    result.append(output)
                }
                return result
            }
        }
    }

    static func exportConfiguredPDF(document: ScanDocument, root: URL, searchable: Bool,
                                    pageSize: PDFPageSize = .a4,
                                    orientation: PDFPageOrientation = .auto) async throws -> URL {
        try await offMain {
            let files = try renderedFiles(document: document, root: root)
            return try withExportDirectory { directory in
                let output = directory.appendingPathComponent(fileName(document, index: nil, suffix: "pdf"))
                try renderConfiguredPDF(batches: [(document, files)], title: document.title, output: output,
                                        searchable: searchable, pageSize: pageSize, orientation: orientation)
                return output
            }
        }
    }

    static func mergePDF(documents: [ScanDocument], root: URL, searchable: Bool,
                         pageSize: PDFPageSize = .a4,
                         orientation: PDFPageOrientation = .auto) async throws -> URL {
        try await offMain {
            guard !documents.isEmpty else { throw Failure.emptyBatch }
            var batches: [(ScanDocument, [URL])] = []
            for document in documents {
                try Task.checkCancellation()
                batches.append((document, try renderedFiles(document: document, root: root)))
            }
            return try withExportDirectory { directory in
                let primaryTitle = documents.first?.title ?? "Mesclado"
                let mergedDoc = ScanDocument(title: "\(primaryTitle)-Mesclado")
                let output = directory.appendingPathComponent(fileName(mergedDoc, index: nil, suffix: "pdf"))
                try renderConfiguredPDF(batches: batches, title: mergedDoc.title, output: output,
                                        searchable: searchable, pageSize: pageSize, orientation: orientation)
                return output
            }
        }
    }

    private static func offMain<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try work()
        }
        return try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    private static func readFile(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw Failure.localFileRequired }
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.fileMissing(url.lastPathComponent) }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw Failure.unreadableFile(url.lastPathComponent) }
            guard let size = values.fileSize, size <= maximumFileBytes else { throw Failure.fileTooLarge }
            guard size > 0 else { throw Failure.emptyFile }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var data = Data()
            // Bound the actual read as well as the initial metadata (file growth).
            while true {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: min(1024 * 1024, maximumFileBytes - data.count + 1)) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
                guard data.count <= maximumFileBytes else { throw Failure.fileTooLarge }
            }
            guard !data.isEmpty else { throw Failure.emptyFile }
            return data
        } catch let failure as Failure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.unreadableFile(url.lastPathComponent)
        }
    }

    private static func decodedImage(_ data: Data) throws -> UIImage {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw Failure.invalidImage
        }
        let w = width.doubleValue, h = height.doubleValue
        guard w.isFinite, h.isFinite, w >= 1, h >= 1, w <= 100_000, h <= 100_000,
              w * h <= maximumSourcePixels else { throw Failure.unsafeImageSize }
        // ImageIO decodes a bounded thumbnail directly, honoring EXIF orientation.
        // For animated/multi-frame images only frame zero is intentionally imported.
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(ScanConfiguration.maximumWorkingDimension),
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw Failure.invalidImage
        }
        // Strip source metadata and flatten transparency onto white, not black.
        return ScanEngine.normalized(UIImage(cgImage: pixels), maximum: ScanConfiguration.maximumWorkingDimension)
    }

    private static func importPDF(_ data: Data) throws -> [ScanInput] {
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw Failure.invalidPDF
        }
        guard let pdf = CGPDFDocument(provider) else {
            if let diagnostic = PDFDocument(data: data) {
                guard !diagnostic.isLocked || diagnostic.unlock(withPassword: "") else {
                    throw Failure.passwordRequired
                }
                if diagnostic.pageCount == 0 { throw Failure.emptyPDF }
            }
            let header = String(decoding: data.prefix(65_536), as: UTF8.self)
            if header.contains("%PDF-"), header.contains("%%EOF"),
               header.contains("/Type /Pages"), header.contains("/Count 0") {
                throw Failure.emptyPDF
            }
            throw Failure.invalidPDF
        }
        guard !pdf.isEncrypted || pdf.isUnlocked || pdf.unlockWithPassword("") else { throw Failure.passwordRequired }
        let count = pdf.numberOfPages
        guard count > 0 else { throw Failure.emptyPDF }
        guard count <= maximumImportPages else { throw Failure.tooManyPages(count) }

        var sizes: [CGSize] = []
        for number in 1...count {
            try Task.checkCancellation()
            guard let page = pdf.page(at: number) else { throw Failure.invalidPDFPage(number) }
            let media = page.getBoxRect(.mediaBox), crop = page.getBoxRect(.cropBox)
            guard validPDFBox(media), validPDFBox(crop), page.rotationAngle % 90 == 0 else {
                throw Failure.unsafePDFBounds(number)
            }
            let box = media.intersection(crop)
            guard validPDFBox(box) else { throw Failure.unsafePDFBounds(number) }
            let sideways = ((page.rotationAngle % 360) + 360) % 180 != 0
            let width = sideways ? box.height : box.width
            let height = sideways ? box.width : box.height
            // 144 dpi for ordinary pages, capped by the existing working dimension.
            let ratio = min(2, ScanConfiguration.maximumWorkingDimension / max(width, height))
            sizes.append(CGSize(width: max(1, floor(width * ratio)), height: max(1, floor(height * ratio))))
        }

        var result: [ScanInput] = []
        var encodedBytes = 0
        for (index, size) in sizes.enumerated() {
            try Task.checkCancellation()
            let input: ScanInput = try autoreleasepool {
                guard let page = pdf.page(at: index + 1) else { throw Failure.invalidPDFPage(index + 1) }
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = true
                format.preferredRange = .standard
                let bounds = CGRect(origin: .zero, size: size)
                let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
                    let context = renderer.cgContext
                    context.setFillColor(UIColor.white.cgColor)
                    context.fill(bounds)
                    context.translateBy(x: 0, y: size.height)
                    context.scaleBy(x: 1, y: -1)
                    // This transform includes /Rotate and non-zero box origins.
                    // Only PDF drawing operators are interpreted, never actions/JS.
                    context.concatenate(page.getDrawingTransform(.cropBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
                    context.drawPDFPage(page)
                }
                guard let jpeg = image.jpegData(compressionQuality: ScanConfiguration.cameraJPEGQuality) else {
                    throw Failure.encodingFailed(index + 1)
                }
                encodedBytes += jpeg.count
                guard encodedBytes <= maximumImportedJPEGBytes else { throw Failure.importBudgetExceeded }
                // Retain JPEG-backed images, not every eagerly rendered bitmap.
                guard let backed = UIImage(data: jpeg) else { throw Failure.encodingFailed(index + 1) }
                // PDF page bounds are already intentional: never run auto-crop.
                return .camera(backed)
            }
            result.append(input)
        }
        return result
    }

    private static func validPDFBox(_ box: CGRect) -> Bool {
        !box.isNull && !box.isInfinite &&
        [box.minX, box.minY, box.maxX, box.maxY, box.width, box.height].allSatisfy { $0.isFinite && abs($0) <= 1_000_000 } &&
        box.width >= 1 && box.height >= 1 && box.width <= 14_400 && box.height <= 14_400
    }

    private static func visiblePageLines(_ page: ScanPage) -> [OCRLine] {
        let masks = (page.overlays ?? []).filter { $0.kind == .redaction }
        guard !masks.isEmpty else { return page.lines }
        guard masks.count <= 512, page.width > 0, page.height > 0,
              page.width <= 3202, page.height <= 3202 else { return [] }
        let width = Double(page.width), height = Double(page.height)
        var boxes: [CGRect] = []
        for mask in masks {
            let right = mask.x + mask.width, bottom = mask.y + mask.height
            guard [mask.x, mask.y, mask.width, mask.height, right, bottom].allSatisfy({ $0.isFinite }),
                  mask.width > 0, mask.height > 0 else { return [] }
            let left = max(0, mask.x), top = max(0, mask.y)
            let clippedRight = min(1, right), clippedBottom = min(1, bottom)
            guard clippedRight > left, clippedBottom > top else { return [] }
            // Match integral raster masks and add one pixel of safety at the edge.
            let x = (floor(left * width) - 1) / width
            let y = (floor(top * height) - 1) / height
            boxes.append(CGRect(x: x, y: y,
                width: (ceil(clippedRight * width) + 1) / width - x,
                height: (ceil(clippedBottom * height) + 1) / height - y))
        }
        var kept: [OCRLine] = []
        for line in page.lines {
            let right = line.x + line.width, upper = line.y + line.height
            guard [line.x, line.y, line.width, line.height, right, upper].allSatisfy({ $0.isFinite }),
                  line.x >= 0, line.y >= 0, line.width > 0, line.height > 0,
                  right <= 1, upper <= 1 else { return [] }
            let bounds = CGRect(x: line.x, y: 1 - upper, width: line.width, height: line.height)
            let covered = boxes.contains {
                bounds.minX <= $0.maxX && bounds.maxX >= $0.minX && bounds.minY <= $0.maxY && bounds.maxY >= $0.minY
            }
            if !covered { kept.append(line) }
        }
        return kept
    }

    private static func visiblePageText(_ page: ScanPage) -> String {
        visiblePageLines(page).map(\.text).joined(separator: "\n")
    }

    private static func configuredPDFBounds(imageSize: CGSize, pageSize: PDFPageSize, orientation: PDFPageOrientation) -> CGRect {
        if let paper = pageSize.pointsSize {
            let portrait = CGSize(width: min(paper.width, paper.height), height: max(paper.width, paper.height))
            let landscape = CGSize(width: max(paper.width, paper.height), height: min(paper.width, paper.height))
            switch orientation {
            case .portrait: return CGRect(origin: .zero, size: portrait)
            case .landscape: return CGRect(origin: .zero, size: landscape)
            case .auto: return CGRect(origin: .zero, size: imageSize.width > imageSize.height ? landscape : portrait)
            }
        }
        let baseWidth = max(72, imageSize.width)
        let baseHeight = max(72, imageSize.height)
        switch orientation {
        case .auto:
            return CGRect(x: 0, y: 0, width: baseWidth, height: baseHeight)
        case .portrait:
            return CGRect(x: 0, y: 0, width: min(baseWidth, baseHeight), height: max(baseWidth, baseHeight))
        case .landscape:
            return CGRect(x: 0, y: 0, width: max(baseWidth, baseHeight), height: min(baseWidth, baseHeight))
        }
    }

    private static func renderConfiguredPDF(batches: [(ScanDocument, [URL])], title: String, output: URL,
                                            searchable: Bool, pageSize: PDFPageSize,
                                            orientation: PDFPageOrientation) throws {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: safeTitle(title), kCGPDFContextCreator as String: "Folha"]
        let defaultBounds = CGRect(origin: .zero, size: pageSize.pointsSize ?? ScanConfiguration.pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: defaultBounds, format: format)
        var renderFailure: Error?
        var pageOrdinal = 0
        let data = renderer.pdfData { pdf in
            for (document, files) in batches {
                for (index, page) in document.pages.enumerated() {
                    pageOrdinal += 1
                    autoreleasepool {
                        do {
                            try Task.checkCancellation()
                            let stored = try decodedImage(readFile(files[index]))
                            let masks = (page.overlays ?? []).filter { $0.kind == .redaction }
                            let protected = try ScanEngine.renderOverlays(stored, overlays: masks)
                            let bounds = configuredPDFBounds(imageSize: protected.size, pageSize: pageSize, orientation: orientation)
                            pdf.beginPage(withBounds: bounds, pageInfo: [:])
                            let inset = (pageSize == .original && bounds.size == protected.size)
                                ? bounds
                                : bounds.insetBy(dx: ScanConfiguration.pageMargin, dy: ScanConfiguration.pageMargin)
                            let frame = ScanEngine.fit(protected.size, inside: inset.width > 0 && inset.height > 0 ? inset : bounds)
                            protected.draw(in: frame)
                            if searchable {
                                let lines = visiblePageLines(page)
                                drawSearchableText(lines, frame: frame, context: pdf.cgContext, pageHeight: bounds.height)
                            }
                        } catch let failure as Failure {
                            renderFailure = failure
                        } catch {
                            renderFailure = Failure.pageExportFailed(pageOrdinal, error.localizedDescription)
                        }
                    }
                    if renderFailure != nil { break }
                }
                if renderFailure != nil { break }
            }
        }
        if let failure = renderFailure { throw failure }
        try data.write(to: output, options: .atomic)
    }

    private static func drawSearchableText(_ lines: [OCRLine], frame: CGRect, context: CGContext, pageHeight: CGFloat) {
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

    private static func renderedFiles(document: ScanDocument, root: URL) throws -> [URL] {
        guard root.isFileURL else { throw Failure.localFileRequired }
        guard !document.pages.isEmpty else { throw Failure.emptyDocument }
        guard Set(document.pages.map(\.id)).count == document.pages.count else { throw Failure.duplicatePages }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let folder = canonicalRoot.appendingPathComponent(document.id.uuidString, isDirectory: true).resolvingSymlinksInPath()
        return try document.pages.enumerated().map { index, page in
            let number = index + 1
            guard folder.deletingLastPathComponent().path == canonicalRoot.path,
                  [page.renderedFile, page.sourceFile, page.thumbnailFile].allSatisfy(safeComponent) else {
                throw Failure.unsafePageFile(number)
            }
            let url = folder.appendingPathComponent(page.renderedFile).resolvingSymlinksInPath()
            guard url.deletingLastPathComponent().path == folder.path else { throw Failure.unsafePageFile(number) }
            guard url.path != folder.appendingPathComponent(page.sourceFile).resolvingSymlinksInPath().path,
                  url.path != folder.appendingPathComponent(page.thumbnailFile).resolvingSymlinksInPath().path else {
                throw Failure.originalInsteadOfRendered(number)
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw Failure.renderedPageMissing(number, page.renderedFile)
            }
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= maximumFileBytes else {
                    throw Failure.renderedPageUnreadable(number, page.renderedFile)
                }
            } catch {
                throw Failure.renderedPageUnreadable(number, page.renderedFile)
            }
            return url
        }
    }

    private static func safeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") &&
        name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func safeTitle(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let ascii = folded.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        let compact = ascii.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let clean = String(compact.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return clean.isEmpty ? "Documento" : clean
    }

    private static func fileName(_ document: ScanDocument, index: Int?, suffix: String) -> String {
        let prefix = index.map { String(format: "%03d-", $0 + 1) } ?? ""
        return "\(prefix)\(safeTitle(document.title))-\(document.id.uuidString).\(suffix)"
    }

    private static func withExportDirectory<T>(_ work: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Folha-Transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var delivered = false
        defer {
            // Only this newly allocated private staging directory is removable.
            // Never remove a source, library derivative, or ScanEngine export.
            if !delivered { try? FileManager.default.removeItem(at: directory) }
        }
        let result = try work(directory)
        try Task.checkCancellation()
        delivered = true
        // Caller owns successful temporary exports until sharing finishes.
        return result
    }
}
