import SwiftUI
import UIKit
import Vision

private struct CropVertex: Identifiable {
    let id: Int
    var x: Double
    var y: Double
    var json: [String: Double] { ["x": x, "y": y] }
}

struct RecoveredPageEditor: View {
    @EnvironmentObject private var store: DocumentStore
    let documentID: UUID
    let pageID: UUID
    @State private var source: UIImage?
    @State private var preview: UIImage?
    @State private var corners = [CropVertex(id: 0, x: 0, y: 1), CropVertex(id: 1, x: 1, y: 1),
                                  CropVertex(id: 2, x: 1, y: 0), CropVertex(id: 3, x: 0, y: 0)]
    @State private var rotation = 0
    @State private var brightness = 0.0
    @State private var contrast = 0.0
    @State private var detail = 100.0
    @State private var adjustmentsEnabled = false
    @State private var cropEnabled = false
    @State private var busy = false
    @State private var errorText: String?
    @State private var notice: String?

    private var document: ScanDocument? { store.documents.first { $0.id == documentID } }
    private var page: ScanPage? { document?.pages.first { $0.id == pageID } }
    private var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Folha").appendingPathComponent(documentID.uuidString)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let source {
                    Text("Arraste os quatro cantos sobre a imagem original.")
                        .font(.footnote).foregroundStyle(.secondary)
                    cropCanvas(source)
                    Toggle("Aplicar recorte manual", isOn: $cropEnabled)
                    HStack {
                        Button("Girar 90 graus", systemImage: "rotate.right") { rotation = (rotation + 1) % 4 }
                        Spacer()
                        Text("\(rotation * 90) graus").font(.caption.monospacedDigit())
                    }
                    Divider()
                    Toggle("Ajustes reconstruidos", isOn: $adjustmentsEnabled)
                    VStack(spacing: 12) {
                        adjustment("Brilho", value: $brightness, range: -50...50)
                        adjustment("Contraste", value: $contrast, range: -50...50)
                        adjustment("Detalhe / fundo", value: $detail, range: 0...100)
                    }.disabled(!adjustmentsEnabled)
                    Text("Ajustes de pixels reconstruidos do comportamento observado. Recorte e perspectiva ainda usam uma implementacao independente.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Previa") { process(save: false) }.buttonStyle(.bordered)
                        Button("Aplicar e salvar") { process(save: true) }.buttonStyle(.borderedProminent)
                    }
                    if let preview {
                        Image(uiImage: preview).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                } else { ProgressView("Abrindo imagem original...") }
            }
            .padding()
        }
        .navigationTitle("Editar pagina")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy)
        .disabled(busy)
        .overlay { if busy { ProgressView("Processando...").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .task { load() }
        .alert("Atencao", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: { Text(errorText ?? "") }
    }

    private func adjustment(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack {
            HStack { Text(title); Spacer(); Text("\(Int(value.wrappedValue))").monospacedDigit() }
            Slider(value: value, in: range, step: 1)
        }
    }

    private func cropCanvas(_ image: UIImage) -> some View {
        GeometryReader { geometry in
            ZStack {
                Image(uiImage: image).resizable().scaledToFill()
                Path { path in
                    for (index, corner) in corners.enumerated() {
                        let point = CGPoint(x: corner.x * geometry.size.width, y: (1 - corner.y) * geometry.size.height)
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    path.closeSubpath()
                }.stroke(.green, lineWidth: 2)
                ForEach(corners) { corner in
                    Circle().fill(.green).overlay(Circle().stroke(.white, lineWidth: 2))
                        .frame(width: 26, height: 26)
                        .position(x: corner.x * geometry.size.width, y: (1 - corner.y) * geometry.size.height)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("crop"))
                            .onChanged { value in
                                guard geometry.size.width > 0, geometry.size.height > 0 else { return }
                                corners[corner.id].x = min(1, max(0, value.location.x / geometry.size.width))
                                corners[corner.id].y = 1 - min(1, max(0, value.location.y / geometry.size.height))
                                cropEnabled = true
                            })
                }
            }.coordinateSpace(name: "crop").clipped()
        }
        .aspectRatio(image.size.width / max(1, image.size.height), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func load() {
        guard let page else { errorText = "Pagina nao encontrada."; return }
        do {
            let data = try Data(contentsOf: folder.appendingPathComponent(page.sourceFile))
            guard let image = UIImage(data: data) else { throw ScanFailure.message("Original ilegivel.") }
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            source = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
            rotation = page.quarterTurns
            cropEnabled = page.autoCrop
            if let c = page.corners {
                corners = [CropVertex(id: 0, x: c.topLeft.x, y: c.topLeft.y),
                           CropVertex(id: 1, x: c.topRight.x, y: c.topRight.y),
                           CropVertex(id: 2, x: c.bottomRight.x, y: c.bottomRight.y),
                           CropVertex(id: 3, x: c.bottomLeft.x, y: c.bottomLeft.y)]
            }
            if let adjustment = page.reconstructedAdjustments {
                adjustmentsEnabled = true
                brightness = Double(adjustment.brightness); contrast = Double(adjustment.contrast)
                detail = Double(adjustment.detail)
            }
            preview = UIImage(contentsOfFile: folder.appendingPathComponent(page.renderedFile).path)
        } catch { errorText = error.localizedDescription }
    }

    private func process(save: Bool) {
        guard let source, let originalPage = page, !busy else { return }
        if cropEnabled && !validPolygon() { errorText = "Os cantos estao cruzados ou formam uma area muito pequena."; return }
        do {
            let encoded = try JSONEncoder().encode(originalPage)
            var fields = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            fields["quarterTurns"] = rotation
            fields["autoCrop"] = cropEnabled
            fields["corners"] = cropEnabled ? ["topLeft": corners[0].json, "topRight": corners[1].json,
                "bottomRight": corners[2].json, "bottomLeft": corners[3].json] as Any : NSNull()
            let setting = ReconstructedAdjustmentContract(brightness: Int32(brightness), contrast: Int32(contrast), detail: Int32(detail))
            fields["reconstructedAdjustments"] = adjustmentsEnabled
                ? ["brightness": setting.brightness, "contrast": setting.contrast, "detail": setting.detail] as Any : NSNull()
            // The recovered adjustment replaces generic enhancement for this edit.
            fields["filter"] = "natural"
            let updated = try JSONDecoder().decode(ScanPage.self, from: JSONSerialization.data(withJSONObject: fields))
            let destination = folder
            busy = true; notice = nil
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    var page = updated
                    let result = try ScanEngine.recoveredPreview(source: source, page: &page)
                    if save { try RecoveredPagePersistence.save(page: page, image: result, original: originalPage, folder: destination) }
                    DispatchQueue.main.async {
                        preview = result; busy = false
                        if save { store.reload(); notice = "Pagina salva; original preservado." }
                    }
                } catch { DispatchQueue.main.async { busy = false; errorText = error.localizedDescription } }
            }
        } catch { errorText = error.localizedDescription }
    }

    private func validPolygon() -> Bool {
        var crosses = [Double]()
        var area = 0.0
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4], c = corners[(i + 2) % 4]
            crosses.append((b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x))
            area += a.x * b.y - b.x * a.y
        }
        return abs(area) > 0.002 && (crosses.allSatisfy { $0 > 0.000001 } || crosses.allSatisfy { $0 < -0.000001 })
    }
}

private enum RecoveredPagePersistence {
    static func save(page: ScanPage, image: UIImage, original: ScanPage, folder: URL) throws {
        let manifest = folder.appendingPathComponent(ScanEngine.recoveredManifestName)
        let before = try Data(contentsOf: manifest)
        var document = try JSONSerialization.jsonObject(with: before) as! [String: Any]
        guard var pages = document["pages"] as? [[String: Any]],
              let index = pages.firstIndex(where: { ($0["id"] as? String)?.lowercased() == page.id.uuidString.lowercased() }),
              pages[index]["renderedFile"] as? String == original.renderedFile else {
            throw ScanFailure.message("A pagina mudou. Reabra antes de salvar.")
        }
        let revision = UUID().uuidString
        let rendered = "\(page.id.uuidString)-\(revision).png"
        let thumbnail = "\(page.id.uuidString)-\(revision)-thumb.png"
        guard let pixels = image.pngData() else { throw ScanFailure.message("Falha ao salvar os pixels.") }
        try pixels.write(to: folder.appendingPathComponent(rendered), options: .atomic)
        let scale = min(1, 320 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let thumb = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let thumbData = thumb.pngData() else { throw ScanFailure.message("Falha na miniatura.") }
        try thumbData.write(to: folder.appendingPathComponent(thumbnail), options: .atomic)
        var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as! [String: Any]
        fields["renderedFile"] = rendered; fields["thumbnailFile"] = thumbnail
        fields["width"] = image.cgImage?.width ?? Int(image.size.width)
        fields["height"] = image.cgImage?.height ?? Int(image.size.height)
        fields["lines"] = []
        do {
            if let cg = image.cgImage {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
                let supported = try request.supportedRecognitionLanguages()
                request.recognitionLanguages = ["pt-BR", "en-US"].filter { supported.contains($0) }
                request.automaticallyDetectsLanguage = true
                try VNImageRequestHandler(cgImage: cg).perform([request])
                fields["lines"] = (request.results ?? []).compactMap { result -> [String: Any]? in
                    guard let text = result.topCandidates(1).first else { return nil }
                    let b = result.boundingBox
                    return ["id": UUID().uuidString, "text": text.string, "confidence": text.confidence,
                            "x": b.minX, "y": b.minY, "width": b.width, "height": b.height]
                }
                fields["ocrWarning"] = NSNull()
            }
        } catch { fields["ocrWarning"] = error.localizedDescription }
        pages[index].merge(fields) { _, new in new }
        document["pages"] = pages
        document["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        guard try Data(contentsOf: manifest) == before else { throw ScanFailure.message("O documento mudou durante a edicao.") }
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifest, options: .atomic)
    }
}
