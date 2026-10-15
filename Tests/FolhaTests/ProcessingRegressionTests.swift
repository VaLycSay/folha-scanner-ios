import XCTest
import UIKit
import PDFKit
@testable import Folha

final class ProcessingRegressionTests: XCTestCase {
    private static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolhaProcessing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func fixture(_ text: String = "", color: UIColor = .white) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1000), format: format).image { renderer in
            color.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 800, height: 1000))
            (text as NSString).draw(in: CGRect(x: 40, y: 80, width: 720, height: 100), withAttributes: [
                .font: UIFont.systemFont(ofSize: 60, weight: .bold), .foregroundColor: UIColor.black
            ])
        }
    }

    private static func page() -> ScanPage {
        ScanPage(id: UUID(), sourceFile: "fixture.source", renderedFile: "fixture.jpg", thumbnailFile: "fixture-thumb.jpg")
    }

    private static func stored(_ document: ScanDocument, root: URL) -> URL {
        root.appendingPathComponent(document.id.uuidString, isDirectory: true)
    }

    private static func manifest(_ document: ScanDocument, root: URL) throws -> Data {
        try Data(contentsOf: stored(document, root: root).appendingPathComponent("document.json"))
    }

    private static func readDocument(_ document: ScanDocument, root: URL) throws -> ScanDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ScanDocument.self, from: manifest(document, root: root))
    }

    // Return top-left RGBA pixels independently from the production renderer.
    private static func rgba(_ image: UIImage) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // Copy CGImage scanlines with the identity transform. A UIKit-style
            // y flip here reverses the buffer rows, making top-left assertions
            // inspect the bottom of the image instead of the rendered overlay.
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return true
        }
        XCTAssertTrue(drew)
        return (bytes, cg.width, cg.height)
    }

    private static func assertBlack(_ image: UIImage, normalized rect: CGRect,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let pixels = try rgba(image)
        let left = Int(ceil(rect.minX * CGFloat(pixels.width)))
        let top = Int(ceil(rect.minY * CGFloat(pixels.height)))
        let right = Int(floor(rect.maxX * CGFloat(pixels.width)))
        let bottom = Int(floor(rect.maxY * CGFloat(pixels.height)))
        XCTAssertLessThan(left, right, file: file, line: line)
        XCTAssertLessThan(top, bottom, file: file, line: line)
        for y in top..<bottom {
            for x in left..<right {
                let offset = (y * pixels.width + x) * 4
                guard pixels.bytes[offset] == 0, pixels.bytes[offset + 1] == 0,
                      pixels.bytes[offset + 2] == 0, pixels.bytes[offset + 3] == 255 else {
                    XCTFail("Nonopaque or nonblack pixel at \(x),\(y)", file: file, line: line)
                    return
                }
            }
        }
    }

    func testRGBAReaderPreservesKnownScanlineOrderAndChannels() throws {
        // An asymmetric raw fixture, independent of ScanEngine and UIKit drawing,
        // calibrates the pixel reader before trusting raster/redaction assertions.
        let expected: [UInt8] = [
            255, 0, 0, 255,     0, 255, 0, 255,
            0, 0, 255, 255,     255, 255, 0, 255,
            0, 0, 0, 255,       255, 255, 255, 255
        ]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(expected) as CFData))
        let flags = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let cg = try XCTUnwrap(CGImage(width: 2, height: 3, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: flags),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let pixels = try Self.rgba(UIImage(cgImage: cg))
        XCTAssertEqual(pixels.width, 2)
        XCTAssertEqual(pixels.height, 3)
        XCTAssertEqual(pixels.bytes, expected)
    }

    func testLegacyManifestWithoutOptionalFieldsAndOldFilterValuesDecodes() throws {
        let encoder = JSONEncoder()
        for filter in [PageFilter.natural, .clean, .grayscale, .document] {
            var original = Self.page()
            original.filter = filter
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
            json.removeValue(forKey: "overlays")
            json.removeValue(forKey: "reconstructedAdjustments")
            let decoded = try JSONDecoder().decode(ScanPage.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(decoded.filter, filter)
            XCTAssertEqual(decoded.id, original.id)
            XCTAssertNil(decoded.overlays)
            XCTAssertNil(decoded.reconstructedAdjustments)
            XCTAssertTrue(decoded.lines.isEmpty)
            XCTAssertFalse(decoded.autoCrop)
        }
        XCTAssertEqual(PageFilter.natural.rawValue, "natural")
        XCTAssertEqual(PageFilter.clean.rawValue, "clean")
        XCTAssertEqual(PageFilter.grayscale.rawValue, "grayscale")
        XCTAssertEqual(PageFilter.document.rawValue, "document")
    }

    func testFilterModesTitlesAndRecoveredOrder() throws {
        XCTAssertEqual(PageFilter.recoveredOrder, [.natural, .lighten, .clean, .document, .blackAndWhite2, .grayscale])
        XCTAssertEqual(PageFilter.recoveredOrder.map(\.nativeModeID), [0, 1, 2, 5, 3, 4])
        XCTAssertEqual(PageFilter.recoveredOrder.map(\.title), ["Original", "Clarear", "Cor magica", "P&B", "P&B 2", "Cinza"])
        XCTAssertEqual(PageFilter.removeShadow.nativeModeID, 6)
        XCTAssertEqual(PageFilter.removeShadow.title, "Remover sombras")
        XCTAssertEqual(PageFilter.allCases.count, 7)
        XCTAssertFalse(PageFilter.recoveredOrder.contains(.removeShadow))
        for filter in PageFilter.allCases {
            XCTAssertEqual(try JSONDecoder().decode(PageFilter.self, from: JSONEncoder().encode(filter)), filter)
            XCTAssertTrue(filter.implementationNote.contains("aproximada"))
        }
    }

    func testOverlayDefaultsAndRoundTrip() throws {
        let text = PageOverlay(kind: .text)
        XCTAssertNil(text.text)
        XCTAssertTrue(text.points.isEmpty)
        XCTAssertEqual(text.x, 0.1)
        XCTAssertEqual(text.y, 0.1)
        XCTAssertEqual(text.width, 0.5)
        XCTAssertEqual(text.height, 0.15)
        XCTAssertEqual(text.lineWidth, 0.006)
        XCTAssertNotEqual(text.id, PageOverlay(kind: .text).id)
        var page = Self.page()
        page.overlays = [text, PageOverlay(kind: .ink, points: [.init(CGPoint(x: 0.2, y: 0.3))]), PageOverlay(kind: .redaction)]
        XCTAssertEqual(try JSONDecoder().decode(ScanPage.self, from: JSONEncoder().encode(page)), page)
    }

    func testCameraInputCropContractAndBytes() async throws {
        try await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            let image = Self.fixture()
            XCTAssertFalse(ScanInput.camera(image).autoCrop)
            XCTAssertTrue(ScanInput.rawCamera(image).autoCrop)
            let png = try XCTUnwrap(image.pngData())
            XCTAssertTrue(ScanInput.photo(png).autoCrop)
            XCTAssertEqual(try ScanInput.photo(png).bytes(), png)
            XCTAssertNotNil(UIImage(data: try ScanInput.rawCamera(image).bytes()))
            XCTAssertEqual(try ScanInput.camera(image).bytes(), try ScanInput.rawCamera(image).bytes())
        }.value
    }

    func testAllIndependentFiltersProduceBoundedImages() async throws {
        try await Task.detached {
            let source = Self.fixture("FOLHA", color: UIColor(white: 0.6, alpha: 1))
            for filter in PageFilter.allCases {
                var page = Self.page()
                page.filter = filter
                let image = try ScanEngine.process(source, page: &page)
                XCTAssertEqual(image.cgImage?.width, 800)
                XCTAssertEqual(image.cgImage?.height, 1000)
                XCTAssertEqual(page.width, 800)
                XCTAssertEqual(page.height, 1000)
            }
            var original = Self.page()
            var lighter = original
            lighter.filter = .lighten
            let before = try Self.rgba(ScanEngine.process(source, page: &original))
            let after = try Self.rgba(ScanEngine.process(source, page: &lighter))
            let offset = (500 * before.width + 400) * 4
            XCTAssertGreaterThan(after.bytes[offset], before.bytes[offset])
        }.value
    }

    func testTextAndInkRasterizeOnWorkerInTopLeftCoordinatesBeforeOCR() async throws {
        try await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            var page = Self.page()
            page.overlays = [
                PageOverlay(kind: .text, text: "PUBLICO FOLHA", x: 0.05, y: 0.05, width: 0.9, height: 0.12),
                PageOverlay(kind: .ink, points: [.init(CGPoint(x: 0.1, y: 0.35)), .init(CGPoint(x: 0.8, y: 0.35))], lineWidth: 0.02)
            ]
            let rendered = try ScanEngine.process(Self.fixture(), page: &page)
            let lines = try ScanEngine.recognize(rendered)
            XCTAssertTrue(lines.map(\.text).joined(separator: " ").uppercased().contains("PUBLICO"))
            try Self.assertBlack(rendered, normalized: CGRect(x: 0.2, y: 0.347, width: 0.5, height: 0.006))
            let pixels = try Self.rgba(rendered)
            let untouched = (850 * pixels.width + 400) * 4
            XCTAssertEqual(pixels.bytes[untouched], 255)
        }.value
    }

    func testTextIsClippedToItsBoundsAndInkCoordinatesAreClamped() async throws {
        try await Task.detached {
            let bounds = CGRect(x: 0.2, y: 0.2, width: 0.25, height: 0.05)
            let text = PageOverlay(kind: .text, text: String(repeating: "MMMMM ", count: 100),
                                   x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height)
            let image = try ScanEngine.renderOverlays(Self.fixture(), overlays: [text])
            let pixels = try Self.rgba(image)
            var changedInside = false
            for y in 0..<pixels.height {
                for x in 0..<pixels.width {
                    let offset = (y * pixels.width + x) * 4
                    if pixels.bytes[offset] < 250 {
                        changedInside = true
                        XCTAssertTrue(bounds.insetBy(dx: -0.002, dy: -0.002).contains(
                            CGPoint(x: Double(x) / Double(pixels.width), y: Double(y) / Double(pixels.height))))
                    }
                }
            }
            XCTAssertTrue(changedInside)
            let ink = PageOverlay(kind: .ink, points: [.init(CGPoint(x: -20, y: 0.5)), .init(CGPoint(x: 20, y: 0.5))])
            XCTAssertNoThrow(try ScanEngine.renderOverlays(Self.fixture(), overlays: [ink]))
        }.value
    }

    func testRedactionWinsAfterFiltersAndAdjustmentsWithoutPixelLeak() async throws {
        try await Task.detached {
            let source = Self.fixture("SEGREDO 98765", color: UIColor(red: 0.7, green: 0.25, blue: 0.4, alpha: 1))
            let mask = PageOverlay(kind: .redaction, x: 0, y: 0, width: 1, height: 0.25)
            for filter in PageFilter.allCases {
                var page = Self.page()
                page.filter = filter
                page.reconstructedAdjustments = .init(brightness: 40, contrast: -20, detail: 75)
                let baseline = try Self.rgba(ScanEngine.process(source, page: &page))
                page.overlays = [mask, PageOverlay(kind: .text, text: "SHOULD ALSO BE MASKED", x: 0, y: 0.02, width: 1, height: 0.1)]
                let rendered = try ScanEngine.process(source, page: &page)
                try Self.assertBlack(rendered, normalized: CGRect(x: 0, y: 0, width: 1, height: 0.25))
                let pixels = try Self.rgba(rendered)
                let bottom = (800 * pixels.width + 400) * 4
                // P&B can legitimately make this unmasked source pixel black.
                // It must remain identical to the same filter without overlays.
                XCTAssertEqual(Array(pixels.bytes[bottom..<bottom + 4]), Array(baseline.bytes[bottom..<bottom + 4]))
            }
        }.value
    }

    func testMalformedOverlaysFailClosed() async throws {
        try await Task.detached {
            let image = Self.fixture()
            let invalid = [
                PageOverlay(kind: .redaction, x: .nan),
                PageOverlay(kind: .redaction, width: -0.1),
                PageOverlay(kind: .redaction, x: 2),
                PageOverlay(kind: .text, height: .infinity),
                PageOverlay(kind: .ink, points: [.init(CGPoint(x: CGFloat.nan, y: 0))]),
                PageOverlay(kind: .ink, lineWidth: .infinity),
                PageOverlay(kind: .text, text: String(repeating: "x", count: 10_001))
            ]
            for overlay in invalid { XCTAssertThrowsError(try ScanEngine.renderOverlays(image, overlays: [overlay])) }
            XCTAssertThrowsError(try ScanEngine.renderOverlays(image, overlays: Array(repeating: PageOverlay(kind: .redaction), count: 513)))
            XCTAssertThrowsError(try ScanEngine.renderOverlays(image, overlays: [
                PageOverlay(kind: .ink, points: Array(repeating: .init(.zero), count: 20_001))
            ]))
            let clipped = try ScanEngine.renderOverlays(image, overlays: [PageOverlay(kind: .redaction, x: -0.1, y: -0.1, width: 0.3, height: 0.3)])
            try Self.assertBlack(clipped, normalized: CGRect(x: 0, y: 0, width: 0.19, height: 0.19))
        }.value
    }

    func testRevisionRedactsRasterThumbnailOCRAndSearchablePDFButKeepsSource() async throws {
        try await Task.detached {
            let root = try Self.temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let document = try ScanEngine.create(inputs: [.camera(Self.fixture("SEGREDO 98765"))], root: root)
            let folder = Self.stored(document, root: root)
            var page = try XCTUnwrap(document.pages.first)
            let original = try Data(contentsOf: folder.appendingPathComponent(page.sourceFile))
            XCTAssertTrue(try ScanEngine.recognize(ScanEngine.image(original)).map(\.text).joined(separator: " ").contains("SEGREDO"))
            page.lines = [OCRLine(text: "SEGREDO STALE", confidence: 1, x: 0.1, y: 0.05, width: 0.8, height: 0.1)]
            page.overlays = [
                PageOverlay(kind: .redaction, x: 0, y: 0, width: 1, height: 0.25),
                PageOverlay(kind: .text, text: "PUBLICO", x: 0.1, y: 0.5, width: 0.8, height: 0.1)
            ]
            var revised = try ScanEngine.revise(document: document, page: page, root: root)
            let result = revised.pages[0]
            XCTAssertEqual(result.id, page.id)
            XCTAssertNil(result.ocrWarning)
            XCTAssertFalse(revised.searchableText.uppercased().contains("SEGREDO"))
            XCTAssertTrue(revised.searchableText.uppercased().contains("PUBLICO"))
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(result.sourceFile)), original)
            XCTAssertTrue(result.renderedFile.hasSuffix(".png"))
            XCTAssertTrue(result.thumbnailFile.hasSuffix(".png"))
            for file in [result.renderedFile, result.thumbnailFile] {
                let image = try ScanEngine.image(Data(contentsOf: folder.appendingPathComponent(file)))
                try Self.assertBlack(image, normalized: CGRect(x: 0, y: 0, width: 1, height: 0.25))
            }
            // Deliberately poison cached OCR outside the mask. Export must run
            // recognition again, not merely filter cached bounding boxes.
            revised.pages[0].lines.append(OCRLine(text: "SEGREDO STALE", confidence: 1, x: 0.1, y: 0.02, width: 0.8, height: 0.1))
            let pdf = try XCTUnwrap(PDFDocument(url: ScanEngine.exportPDF(document: revised, root: root, searchable: true)))
            XCTAssertEqual(pdf.pageCount, 1)
            XCTAssertFalse((pdf.string ?? "").uppercased().contains("SEGREDO"))
            XCTAssertTrue((pdf.string ?? "").uppercased().contains("PUBLICO"))
            let pdfPage = try XCTUnwrap(pdf.page(at: 0))
            let preview = pdfPage.thumbnail(of: CGSize(width: 595, height: 842), for: .mediaBox)
            try Self.assertBlack(preview, normalized: CGRect(x: 0.15, y: 0.12, width: 0.7, height: 0.06))
        }.value
    }

    func testAppendReconcilesLatestManifestAndKeepsPageOrderAndSources() async throws {
        try await Task.detached {
            let root = try Self.temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let first = Self.fixture(color: .white)
            let second = Self.fixture(color: .lightGray)
            let initial = try ScanEngine.create(inputs: [.camera(first), .camera(second)], root: root)
            let folder = Self.stored(initial, root: root)
            let originals = try initial.pages.map { try Data(contentsOf: folder.appendingPathComponent($0.sourceFile)) }
            var reordered = initial
            reordered.pages.reverse()
            reordered.title = "Ordem atual"
            try ScanEngine.writeManifest(reordered, folder: folder)
            let appended = try ScanEngine.append(inputs: [.camera(first), .rawCamera(second)], to: initial, root: root)
            XCTAssertEqual(Array(appended.pages.prefix(2)).map(\.id), reordered.pages.map(\.id))
            XCTAssertEqual(appended.pages.count, 4)
            XCTAssertEqual(Set(appended.pages.map(\.id)).count, 4)
            XCTAssertEqual(appended.title, "Ordem atual")
            XCTAssertFalse(appended.pages[2].autoCrop)
            XCTAssertTrue(appended.pages[3].autoCrop)
            for (index, page) in initial.pages.enumerated() {
                XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(page.sourceFile)), originals[index])
            }
            let again = try ScanEngine.append(inputs: [.camera(first)], to: initial, root: root)
            XCTAssertEqual(again.pages.count, 5)
            XCTAssertEqual(Array(again.pages.prefix(4)).map(\.id), appended.pages.map(\.id))
            XCTAssertEqual(try Self.readDocument(again, root: root).pages.map(\.id), again.pages.map(\.id))
            let before = try Self.manifest(again, root: root)
            let unchanged = try ScanEngine.append(inputs: [], to: initial, root: root)
            XCTAssertEqual(unchanged.pages.map(\.id), again.pages.map(\.id))
            XCTAssertEqual(try Self.manifest(again, root: root), before)
        }.value
    }

    func testAppendFailureDoesNotPublishPartialBatch() async throws {
        try await Task.detached {
            let root = try Self.temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let document = try ScanEngine.create(inputs: [.camera(Self.fixture())], root: root)
            let before = try Self.manifest(document, root: root)
            let folder = Self.stored(document, root: root)
            let page = document.pages[0]
            let source = try Data(contentsOf: folder.appendingPathComponent(page.sourceFile))
            XCTAssertThrowsError(try ScanEngine.append(inputs: [.camera(Self.fixture()), .photo(Data([0, 1, 2]))], to: document, root: root))
            XCTAssertEqual(try Self.manifest(document, root: root), before)
            XCTAssertEqual(try Self.readDocument(document, root: root).pages.map(\.id), [page.id])
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(page.sourceFile)), source)
            XCTAssertNotNil(UIImage(contentsOfFile: folder.appendingPathComponent(page.renderedFile).path))
        }.value
    }

    func testReplaceKeepsIdentityPositionAndHistoricalSourceAndResetsGeometry() async throws {
        try await Task.detached {
            let root = try Self.temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let initial = try ScanEngine.create(inputs: [.camera(Self.fixture()), .camera(Self.fixture(color: .lightGray))], root: root)
            let folder = Self.stored(initial, root: root)
            var edited = initial.pages[0]
            edited.filter = .grayscale
            edited.quarterTurns = 1
            edited.overlays = [PageOverlay(kind: .redaction)]
            let revised = try ScanEngine.revise(document: initial, page: edited, root: root)
            let latest = try ScanEngine.append(inputs: [.camera(Self.fixture())], to: revised, root: root)
            let oldSource = try Data(contentsOf: folder.appendingPathComponent(edited.sourceFile))
            let replacementBytes = try XCTUnwrap(Self.fixture("NOVA PAGINA").pngData())
            let replaced = try ScanEngine.replace(input: .photo(replacementBytes), in: initial, pageID: edited.id, root: root)
            XCTAssertEqual(replaced.pages.map(\.id), latest.pages.map(\.id))
            XCTAssertEqual(replaced.pages[0].id, edited.id)
            XCTAssertNotEqual(replaced.pages[0].sourceFile, edited.sourceFile)
            XCTAssertEqual(replaced.pages[0].filter, .grayscale)
            XCTAssertEqual(replaced.pages[0].quarterTurns, 0)
            XCTAssertNil(replaced.pages[0].overlays)
            XCTAssertTrue(replaced.pages[0].autoCrop)
            XCTAssertEqual(replaced.pages[1], latest.pages[1])
            XCTAssertEqual(replaced.pages[2], latest.pages[2])
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(edited.sourceFile)), oldSource)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(replaced.pages[0].sourceFile)), replacementBytes)
            XCTAssertEqual(try Self.readDocument(replaced, root: root).pages, replaced.pages)
            XCTAssertThrowsError(try ScanEngine.revise(document: revised, page: edited, root: root))
        }.value
    }

    func testFailedOrMissingReplacementAndDuplicateIDsLeaveManifestUntouched() async throws {
        try await Task.detached {
            let root = try Self.temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let document = try ScanEngine.create(inputs: [.camera(Self.fixture())], root: root)
            let before = try Self.manifest(document, root: root)
            XCTAssertThrowsError(try ScanEngine.replace(input: .photo(Data()), in: document, pageID: document.pages[0].id, root: root))
            XCTAssertThrowsError(try ScanEngine.replace(input: .camera(Self.fixture()), in: document, pageID: UUID(), root: root))
            var invalid = document
            invalid.pages.append(invalid.pages[0])
            XCTAssertThrowsError(try ScanEngine.append(inputs: [.camera(Self.fixture())], to: invalid, root: root))
            XCTAssertEqual(try Self.manifest(document, root: root), before)
            // A stale editor cannot resurrect a page deleted from the manifest.
            var deleted = document
            deleted.pages = []
            try ScanEngine.writeManifest(deleted, folder: Self.stored(document, root: root))
            XCTAssertThrowsError(try ScanEngine.replace(input: .camera(Self.fixture()), in: document, pageID: document.pages[0].id, root: root))
            XCTAssertTrue(try Self.readDocument(document, root: root).pages.isEmpty)
        }.value
    }
}
