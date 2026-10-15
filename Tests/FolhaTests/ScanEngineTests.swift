import XCTest
import UIKit
import PDFKit
@testable import Folha

@MainActor
final class ScanEngineTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FolhaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fixture(_ label: String = "FOLHA TESTE 123") -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1200), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 1200))
            (label as NSString).draw(in: CGRect(x: 60, y: 100, width: 780, height: 130), withAttributes: [
                .font: UIFont.systemFont(ofSize: 64, weight: .medium),
                .foregroundColor: UIColor.black
            ])
        }
    }

    func testAspectFitPreservesRatioAndFitsBounds() {
        let bounds = CGRect(x: 20, y: 30, width: 500, height: 750)
        for source in [CGSize(width: 1600, height: 900), CGSize(width: 900, height: 1600), CGSize(width: 800, height: 800)] {
            let fitted = ScanEngine.fit(source, inside: bounds)
            XCTAssertEqual(fitted.width / fitted.height, source.width / source.height, accuracy: 0.0001)
            XCTAssertEqual(fitted.midX, bounds.midX, accuracy: 0.0001)
            XCTAssertEqual(fitted.midY, bounds.midY, accuracy: 0.0001)
            XCTAssertLessThanOrEqual(fitted.width, bounds.width + 0.0001)
            XCTAssertLessThanOrEqual(fitted.height, bounds.height + 0.0001)
        }
    }

    func testZeroDimensionsReturnEmptyFrame() {
        XCTAssertEqual(ScanEngine.fit(.zero, inside: CGRect(x: 0, y: 0, width: 100, height: 100)), .zero)
    }

    func testExportNameHandlesUnicodeAndSeparators() {
        let id = UUID()
        let name = ScanEngine.exportFileName(title: "  ../A\u{00E7}\u{00E3}o: contrato / 2026?  ", id: id)
        XCTAssertTrue(name.hasPrefix("A\u{00E7}\u{00E3}o contrato  2026-"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertTrue(name.hasSuffix("\(id.uuidString).pdf"))
        XCTAssertEqual(name, ScanEngine.exportFileName(title: "  ../A\u{00E7}\u{00E3}o: contrato / 2026?  ", id: id))
        XCTAssertTrue(ScanEngine.exportFileName(title: "/?:", id: id).hasPrefix("Documento-"))
    }

    func testEmptyInputFailsWithoutDocument() throws {
        XCTAssertThrowsError(try ScanEngine.create(inputs: [], root: root()))
    }

    func testImportKeepsInputBytesAndPageCount() throws {
        let folder = try root()
        let first = try XCTUnwrap(fixture("PAGINA UM").pngData())
        let second = try XCTUnwrap(fixture("PAGINA DOIS").pngData())
        let document = try ScanEngine.create(inputs: [.photo(first), .photo(second)], root: folder)
        XCTAssertEqual(document.pages.count, 2)
        let stored = folder.appendingPathComponent(document.id.uuidString)
        XCTAssertEqual(try Data(contentsOf: stored.appendingPathComponent(document.pages[0].sourceFile)), first)
        XCTAssertEqual(try Data(contentsOf: stored.appendingPathComponent(document.pages[1].sourceFile)), second)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScanDocument.self, from: Data(contentsOf: stored.appendingPathComponent("document.json")))
        XCTAssertEqual(decoded.pages.map(\.id), document.pages.map(\.id))
    }

    func testOCRRecognizesPrintedFixture() throws {
        let lines = try ScanEngine.recognize(fixture())
        XCTAssertTrue(lines.map(\.text).joined(separator: " ").uppercased().contains("FOLHA"))
        for line in lines {
            XCTAssertGreaterThan(line.width, 0)
            XCTAssertGreaterThan(line.height, 0)
            XCTAssertGreaterThanOrEqual(line.x, 0)
            XCTAssertGreaterThanOrEqual(line.y, 0)
        }
    }

    func testRevisionKeepsSourceAndRotatesImage() throws {
        let folder = try root()
        let document = try ScanEngine.create(inputs: [.camera(fixture())], root: folder)
        let stored = folder.appendingPathComponent(document.id.uuidString)
        let source = try Data(contentsOf: stored.appendingPathComponent(document.pages[0].sourceFile))
        var page = document.pages[0]
        page.quarterTurns = 1
        page.filter = .grayscale
        let revised = try ScanEngine.revise(document: document, page: page, root: folder)
        XCTAssertEqual(try Data(contentsOf: stored.appendingPathComponent(revised.pages[0].sourceFile)), source)
        XCTAssertNotEqual(revised.pages[0].renderedFile, page.renderedFile)
        XCTAssertEqual(revised.pages[0].width, page.height)
        XCTAssertEqual(revised.pages[0].height, page.width)
    }

    func testPDFContainsEveryPageAndTextLayer() throws {
        let folder = try root()
        var document = try ScanEngine.create(inputs: [.camera(fixture()), .camera(fixture("SEGUNDA PAGINA"))], root: folder)
        document.pages[0].lines = [OCRLine(text: "FOLHA TESTE 123", confidence: 1,
            x: 60.0 / 900, y: 1 - 230.0 / 1200, width: 780.0 / 900, height: 130.0 / 1200)]
        let url = try ScanEngine.exportPDF(document: document, root: folder, searchable: true)
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(pdf.pageCount, 2)
        XCTAssertTrue((pdf.string ?? "").contains("FOLHA"))
        let repeated = try ScanEngine.exportPDF(document: document, root: folder, searchable: true)
        XCTAssertEqual(url, repeated)
    }

    func testMissingPagePreventsPartialPDF() throws {
        let folder = try root()
        var document = try ScanEngine.create(inputs: [.camera(fixture())], root: folder)
        document.pages[0].renderedFile = "missing-file.jpg"
        XCTAssertThrowsError(try ScanEngine.exportPDF(document: document, root: folder, searchable: false))
    }
}
