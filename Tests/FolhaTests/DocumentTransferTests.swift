import XCTest
import UIKit
import PDFKit
@testable import Folha

@MainActor
final class DocumentTransferTests: XCTestCase {
    private struct PDFSpec {
        var box: CGRect
        var rotation: Int = 0
        var color: String = "1 0 0"
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TransferTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func keepForCleanup(_ urls: [URL]) {
        let directories = Set(urls.map { $0.deletingLastPathComponent() })
        addTeardownBlock {
            for directory in directories { try? FileManager.default.removeItem(at: directory) }
        }
    }

    // Minimal synthetic PDFs with real xref offsets; no vendor fixtures/assets.
    // Raw construction permits zero pages, non-zero origins and invalid bounds.
    private func pdfData(_ pages: [PDFSpec]) -> Data {
        let kids = pages.indices.map { "\(3 + $0 * 2) 0 R" }.joined(separator: " ")
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [\(kids)] /Count \(pages.count) >>"]
        for (index, page) in pages.enumerated() {
            let b = page.box
            let stream = "q \(page.color) rg \(b.minX + 10) \(b.minY + 10) \(b.width - 20) \(b.height - 20) re f Q\n"
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [\(b.minX) \(b.minY) \(b.maxX) \(b.maxY)] /Rotate \(page.rotation) /Resources << >> /Contents \(4 + index * 2) 0 R >>")
            objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)endstream")
        }
        var data = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let start = data.count
        var trailer = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { trailer += String(format: "%010d 00000 n \n", offset) }
        trailer += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n"
        data.append(Data(trailer.utf8))
        return data
    }

    private func writePDF(_ pages: [PDFSpec]) throws -> URL {
        let url = try root().appendingPathComponent("synthetic.pdf")
        try pdfData(pages).write(to: url)
        return url
    }

    private func fixture(_ color: UIColor, size: CGSize = CGSize(width: 200, height: 300)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            color.setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func pixel(_ image: UIImage, x: Int, y: Int) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        let sample = try XCTUnwrap(cg.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        XCTAssertTrue(drawn)
        return bytes
    }

    private func makeDocument(root: URL, title: String = "Documento", colors: [UIColor] = [.white]) throws -> ScanDocument {
        var document = ScanDocument(title: title)
        let folder = root.appendingPathComponent(document.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for color in colors {
            let id = UUID()
            let page = ScanPage(id: id, sourceFile: "\(id).source", renderedFile: "\(id).png",
                thumbnailFile: "\(id)-thumb.png", width: 200, height: 300)
            try Data("PRIVATE ORIGINAL NEVER SHARE".utf8).write(to: folder.appendingPathComponent(page.sourceFile))
            try XCTUnwrap(fixture(color).pngData()).write(to: folder.appendingPathComponent(page.renderedFile))
            document.pages.append(page)
        }
        return document
    }

    private func line(_ text: String, y: Double = 0.1, height: Double = 0.1) -> OCRLine {
        OCRLine(text: text, confidence: 1, x: 0.1, y: y, width: 0.8, height: height)
    }

    private func topMask() -> PageOverlay {
        PageOverlay(kind: .redaction, x: 0, y: 0, width: 1, height: 0.25)
    }

    private func expectFailure(_ expected: DocumentTransfer.Failure, _ operation: () async throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? DocumentTransfer.Failure, expected, file: file, line: line)
        }
    }

    func testImportMultipagePDFPreservesOrderWhiteBackgroundAndDisablesRecrop() async throws {
        let url = try writePDF([
            PDFSpec(box: CGRect(x: 0, y: 0, width: 100, height: 200)),
            PDFSpec(box: CGRect(x: 0, y: 0, width: 200, height: 100), color: "0 0 1")
        ])
        let before = try Data(contentsOf: url)
        let inputs = try await DocumentTransfer.importFile(url)
        XCTAssertEqual(inputs.count, 2)
        for input in inputs { XCTAssertFalse(input.autoCrop) }
        guard case .camera(let first) = inputs[0], case .camera(let second) = inputs[1] else {
            return XCTFail("PDF imports must use camera inputs to preserve page bounds")
        }
        XCTAssertEqual(first.size, CGSize(width: 200, height: 400))
        XCTAssertEqual(second.size, CGSize(width: 400, height: 200))
        let red = try pixel(first, x: 100, y: 200), blue = try pixel(second, x: 200, y: 100)
        XCTAssertGreaterThan(red[0], 220)
        XCTAssertLessThan(red[2], 30)
        XCTAssertGreaterThan(blue[2], 220)
        XCTAssertLessThan(blue[0], 30)
        let white = try pixel(first, x: 2, y: 2)
        XCTAssertTrue(white.prefix(3).allSatisfy { $0 > 240 })
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testImportHonorsRotationAndNonZeroPageOrigin() async throws {
        for rotation in [90, 270, -90] {
            let url = try writePDF([PDFSpec(box: CGRect(x: 30, y: 50, width: 100, height: 200), rotation: rotation)])
            let inputs = try await DocumentTransfer.importFile(url)
            guard case .camera(let image) = inputs[0] else { return XCTFail("Expected camera input") }
            XCTAssertEqual(image.size, CGSize(width: 400, height: 200))
            let middle = try pixel(image, x: 200, y: 100)
            XCTAssertGreaterThan(middle[0], 220)
            XCTAssertLessThan(middle[1], 30)
            XCTAssertTrue(try pixel(image, x: 2, y: 2).prefix(3).allSatisfy { $0 > 240 })
        }
    }

    func testPDFWorkingDimensionsAreBoundedWithoutChangingAspectRatio() async throws {
        let url = try writePDF([PDFSpec(box: CGRect(x: 0, y: 0, width: 2400, height: 1200))])
        let inputs = try await DocumentTransfer.importFile(url)
        guard case .camera(let image) = inputs[0] else { return XCTFail("Expected camera input") }
        XCTAssertEqual(image.size.width, ScanConfiguration.maximumWorkingDimension)
        XCTAssertEqual(image.size.width / image.size.height, 2, accuracy: 0.001)
    }

    func testNativeParsersRejectZeroPageFixtureAndRandomDataWhileEmptyFileIsDistinct() async throws {
        let zeroPagePDF = try writePDF([])
        let zeroPageData = try Data(contentsOf: zeroPagePDF)
        XCTAssertFalse(zeroPageData.isEmpty)
        // CI 38732369341 and 38736477988 establish that neither Apple parser
        // recognizes this zero-page fixture. A structural /Count 0 is not a
        // successful native parse and must not be used to infer emptyPDF.
        // Keep exact rejection assertions; emptyPDF is reserved for a native
        // parser that actually recognizes an unlocked, zero-page document.
        let provider = try XCTUnwrap(CGDataProvider(data: zeroPageData as CFData))
        XCTAssertNil(CGPDFDocument(provider))
        XCTAssertNil(PDFDocument(data: zeroPageData))
        await expectFailure(.invalidPDF) { _ = try await DocumentTransfer.importFile(zeroPagePDF) }
        let invalid = try root().appendingPathComponent("invalid.pdf")
        try Data("not a PDF".utf8).write(to: invalid)
        await expectFailure(.invalidPDF) { _ = try await DocumentTransfer.importFile(invalid) }
        let empty = try root().appendingPathComponent("empty.pdf")
        try Data().write(to: empty)
        await expectFailure(.emptyFile) { _ = try await DocumentTransfer.importFile(empty) }
    }

    func testPDFHeaderAndZeroCountTokensDoNotMakeInvalidDataAnEmptyPDF() async throws {
        let invalid = try root().appendingPathComponent("fake-empty.pdf")
        // The page-tree-looking text is only a comment; there are no objects,
        // catalog, cross-reference table or trailer establishing a document.
        let data = Data("%PDF-1.4\n% /Type /Pages /Kids [] /Count 0\n%%EOF\n".utf8)
        try data.write(to: invalid)
        XCTAssertNil(PDFDocument(data: data))
        await expectFailure(.invalidPDF) { _ = try await DocumentTransfer.importFile(invalid) }
    }

    func testOneWhitePDFPageIsNotAZeroPageDocument() async throws {
        let url = try writePDF([PDFSpec(box: CGRect(x: 0, y: 0, width: 100, height: 200), color: "1 1 1")])
        let inputs = try await DocumentTransfer.importFile(url)
        XCTAssertEqual(inputs.count, 1)
        guard case .camera(let image) = inputs[0] else { return XCTFail("Expected camera input") }
        XCTAssertFalse(inputs[0].autoCrop)
        XCTAssertEqual(image.size, CGSize(width: 200, height: 400))
        XCTAssertTrue(try pixel(image, x: 100, y: 200).prefix(3).allSatisfy { $0 > 240 })
    }

    func testPasswordProtectedPDFIsRejected() async throws {
        let data = pdfData([PDFSpec(box: CGRect(x: 0, y: 0, width: 100, height: 200))])
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let url = try root().appendingPathComponent("locked.pdf")
        XCTAssertTrue(pdf.write(to: url, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner-secret"]))
        await expectFailure(.passwordRequired) { _ = try await DocumentTransfer.importFile(url) }
    }

    func testPageCountBoundsAndFileSizeLimits() async throws {
        let many = try writePDF(Array(repeating: PDFSpec(box: CGRect(x: 0, y: 0, width: 30, height: 40)), count: 51))
        await expectFailure(.tooManyPages(51)) { _ = try await DocumentTransfer.importFile(many) }
        let badBounds = try writePDF([PDFSpec(box: CGRect(x: 0, y: 0, width: 20_000, height: 200))])
        await expectFailure(.unsafePDFBounds(1)) { _ = try await DocumentTransfer.importFile(badBounds) }
        let large = try root().appendingPathComponent("large.pdf")
        try Data([0]).write(to: large)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(DocumentTransfer.maximumFileBytes + 1))
        try handle.close()
        await expectFailure(.fileTooLarge) { _ = try await DocumentTransfer.importFile(large) }
    }

    func testLocalImageImportAndUnsupportedInputs() async throws {
        let url = try root().appendingPathComponent("local.png")
        try XCTUnwrap(fixture(.blue).pngData()).write(to: url)
        let inputs = try await DocumentTransfer.importFile(url)
        XCTAssertEqual(inputs.count, 1)
        guard case .photo(let jpeg) = inputs[0] else { return XCTFail("Expected photo input") }
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xff, 0xd8])
        let image = try XCTUnwrap(UIImage(data: jpeg))
        XCTAssertEqual(image.size, CGSize(width: 200, height: 300))
        let unsupported = try root().appendingPathComponent("not-an-image.docx")
        try Data("No pretend Word converter".utf8).write(to: unsupported)
        await expectFailure(.invalidImage) { _ = try await DocumentTransfer.importFile(unsupported) }
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/document.pdf"))
        await expectFailure(.localFileRequired) { _ = try await DocumentTransfer.importFile(remote) }
    }

    func testVisibleTextConvertsVisionCoordinatesAndDropsTouchingLines() throws {
        var document = try makeDocument(root: root())
        document.pages[0].overlays = [topMask()]
        document.pages[0].lines = [line("SECRET", y: 0.8), line("TOUCHING", y: 0.7, height: 0.05), line("PUBLIC")]
        XCTAssertEqual(DocumentTransfer.visibleText(document: document), "PUBLIC")
    }

    func testInvalidRedactionOrOCRBoundsHideEntireRedactedPage() throws {
        var document = try makeDocument(root: root())
        document.pages[0].overlays = [topMask()]
        document.pages[0].lines = [line("PUBLIC"), line("UNKNOWN")]
        document.pages[0].lines[1].x = .nan
        XCTAssertEqual(DocumentTransfer.visibleText(document: document), "")
        document.pages[0].lines = [line("PUBLIC")]
        document.pages[0].overlays?[0].width = .infinity
        XCTAssertEqual(DocumentTransfer.visibleText(document: document), "")
        document.pages[0].overlays = [topMask()]
        document.pages[0].width = 0
        XCTAssertEqual(DocumentTransfer.visibleText(document: document), "")
    }

    func testExportTextUsesSharedRedactionFilterAndPreservesPageAndLineOrder() async throws {
        let root = try root()
        var document = try makeDocument(root: root, colors: [.white, .white])
        document.pages[0].overlays = [topMask()]
        document.pages[0].lines = [line("SECRET", y: 0.8), line("FIRST"), line("SECOND", y: 0.4)]
        document.pages[1].lines = [line("THIRD")]
        let url = try await DocumentTransfer.exportText(document: document, root: root)
        keepForCleanup([url])
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, "FIRST\nSECOND\n\nTHIRD")
        XCTAssertEqual(text, DocumentTransfer.visibleText(document: document))
        XCTAssertFalse(text.contains("SECRET"))
    }

    func testImageExportUsesRenderedPagesAndReappliesMasksInInputOrder() async throws {
        let root = try root()
        var document = try makeDocument(root: root, colors: [.blue, .red])
        document.pages[0].overlays = [topMask()]
        let source = root.appendingPathComponent(document.id.uuidString).appendingPathComponent(document.pages[0].sourceFile)
        let original = try Data(contentsOf: source)
        let urls = try await DocumentTransfer.exportImages(document: document, root: root)
        keepForCleanup(urls)
        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(urls[0].lastPathComponent.hasPrefix("001-"))
        XCTAssertTrue(urls[1].lastPathComponent.hasPrefix("002-"))
        XCTAssertTrue(urls.allSatisfy { $0.pathExtension == "jpg" })
        let firstData = try Data(contentsOf: urls[0])
        XCTAssertEqual(Array(firstData.prefix(2)), [0xff, 0xd8])
        let first = try XCTUnwrap(UIImage(data: firstData))
        let second = try XCTUnwrap(UIImage(contentsOfFile: urls[1].path))
        XCTAssertTrue(try pixel(first, x: 100, y: 25).prefix(3).allSatisfy { $0 < 20 })
        XCTAssertGreaterThan(try pixel(first, x: 100, y: 250)[2], 220)
        XCTAssertGreaterThan(try pixel(second, x: 100, y: 250)[0], 220)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testMissingPagesAndOriginalAliasesNeverFallBackToSource() async throws {
        let root = try root()
        var document = try makeDocument(root: root, colors: [.white, .white])
        document.pages[1].renderedFile = "missing.png"
        await expectFailure(.renderedPageMissing(2, "missing.png")) {
            _ = try await DocumentTransfer.exportImages(document: document, root: root)
        }
        await expectFailure(.renderedPageMissing(2, "missing.png")) {
            _ = try await DocumentTransfer.exportText(document: document, root: root)
        }
        document.pages = [document.pages[0]]
        document.pages[0].renderedFile = document.pages[0].sourceFile
        await expectFailure(.originalInsteadOfRendered(1)) {
            _ = try await DocumentTransfer.exportImages(document: document, root: root)
        }
        document.pages[0].renderedFile = "../outside.png"
        await expectFailure(.unsafePageFile(1)) {
            _ = try await DocumentTransfer.exportImages(document: document, root: root)
        }
    }

    func testTemporaryExportsHaveSafeFallbackNamesAndUniqueDirectories() async throws {
        let root = try root()
        let document = try makeDocument(root: root, title: "../../\\?:\n")
        let first = try await DocumentTransfer.exportText(document: document, root: root)
        keepForCleanup([first])
        let second = try await DocumentTransfer.exportText(document: document, root: root)
        keepForCleanup([second])
        XCTAssertTrue(first.lastPathComponent.hasPrefix("Documento-"))
        XCTAssertNotEqual(first.deletingLastPathComponent(), second.deletingLastPathComponent())
        XCTAssertTrue(first.deletingLastPathComponent().lastPathComponent.hasPrefix("Folha-Transfer-"))
        XCTAssertFalse(first.path.hasPrefix(root.path + "/"))
    }

    func testBatchPDFExportPreservesOrderAndRepeatedDocuments() async throws {
        let root = try root()
        var first = try makeDocument(root: root, title: "FIRST")
        var second = try makeDocument(root: root, title: "SECOND")
        first.pages[0].lines = [line("FIRST")]
        second.pages[0].lines = [line("SECOND")]
        let urls = try await DocumentTransfer.exportPDFs(documents: [second, first, second], root: root, searchable: true)
        keepForCleanup(urls)
        XCTAssertEqual(urls.count, 3)
        XCTAssertEqual(Set(urls).count, 3)
        for (index, expected) in ["SECOND", "FIRST", "SECOND"].enumerated() {
            let pdf = try XCTUnwrap(PDFDocument(url: urls[index]))
            XCTAssertEqual(pdf.pageCount, 1)
            XCTAssertTrue((pdf.string ?? "").contains(expected))
        }
    }

    func testBatchPDFFailsInsteadOfReturningSuccessfulPrefix() async throws {
        let root = try root()
        let valid = try makeDocument(root: root)
        var invalid = try makeDocument(root: root)
        invalid.pages[0].renderedFile = "missing.png"
        await expectFailure(.renderedPageMissing(1, "missing.png")) {
            _ = try await DocumentTransfer.exportPDFs(documents: [valid, invalid], root: root, searchable: false)
        }
        // A failure after preflight must also throw instead of returning [valid].
        invalid.pages[0].renderedFile = invalid.pages[0].id.uuidString + ".png"
        invalid.pages[0].overlays = [PageOverlay(kind: .redaction, width: -1)]
        do {
            _ = try await DocumentTransfer.exportPDFs(documents: [valid, invalid], root: root, searchable: false)
            XCTFail("An invalid redaction must fail the complete batch")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testEmptyDocumentsAndEmptyBatchAreRejected() async throws {
        let root = try root()
        let document = ScanDocument(title: "Empty")
        XCTAssertEqual(DocumentTransfer.visibleText(document: document), "")
        await expectFailure(.emptyDocument) { _ = try await DocumentTransfer.exportImages(document: document, root: root) }
        await expectFailure(.emptyDocument) { _ = try await DocumentTransfer.exportText(document: document, root: root) }
        await expectFailure(.emptyBatch) { _ = try await DocumentTransfer.exportPDFs(documents: [], root: root, searchable: false) }
    }
}
