import SwiftUI
import UIKit

// Serial, versioned work keeps decoding, rendering, pixel loops and Vision off MainActor.
// Synchronous Core Image/Vision cannot be interrupted; obsolete results are never published.
private final class EditorImageWorker: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var revision: UInt64 = 0

    init(qos: DispatchQoS = .userInitiated) {
        self.queue = DispatchQueue(label: "com.valyc.editor.preview", qos: qos)
    }

    func invalidate(_ value: UInt64) {
        lock.lock(); revision = value; lock.unlock()
    }
    private func accepts(_ value: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value == revision
    }
    func perform<Value>(revision: UInt64, delay: TimeInterval = 0,
                        work: @escaping () throws -> Value,
                        completion: @escaping (Result<Value, Error>) -> Void) {
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            guard accepts(revision) else { return }
            let result = autoreleasepool { Result { try work() } }
            guard accepts(revision) else { return }
            DispatchQueue.main.async { [self] in
                guard accepts(revision) else { return }
                completion(result)
            }
        }
    }
}

@MainActor
private final class EditorViewModel: ObservableObject {
    enum Work { case loading, preview, borders, ocr }
    enum GeometryChange { case crop, rotate(Int), unlockCrop, detectBorders }

    @Published private(set) var original: ScanPage?
    @Published private(set) var draft: ScanPage?
    @Published private(set) var source: UIImage?
    @Published private(set) var preview: UIImage?
    @Published private(set) var stage: EditorStage = .crop
    @Published private(set) var adjustments = EditorAdjustmentState()
    @Published private(set) var work: Work?
    @Published private(set) var previewReady = false
    @Published var saving = false
    @Published var error: String?
    @Published var notice: String?
    @Published var sheet: EditorSheet?
    @Published var pendingGeometry: GeometryChange?
    @Published private(set) var recognizedText = ""
    private var folder: URL?
    private var cropSnapshot: ScanPage?
    private(set) var adjustmentSnapshot: ScanPage?
    private var adjustmentTextSnapshot = ""
    private var versions = EditorPreviewRevision()
    private let worker = EditorImageWorker()
    private var active = false

    var hasChanges: Bool { draft != original }
    var hasOverlays: Bool { !(draft?.overlays ?? []).isEmpty }
    var hasOCR: Bool { !(draft?.lines ?? []).isEmpty || !(original?.lines ?? []).isEmpty || !recognizedText.isEmpty }
    var controlsBlocked: Bool { saving || work == .loading || work == .borders || work == .ocr }
    var corners: PageCorners {
        guard let draft, draft.autoCrop else { return EditorGeometry.fullPage }
        return draft.corners ?? EditorGeometry.fullPage
    }
    var turns: Int { ((draft?.quarterTurns ?? 0) % 4 + 4) % 4 }
    var geometryWarning: String {
        var result = "O OCR sera invalidado e reconhecido novamente ao salvar."
        if hasOverlays {
            result += " Para mudar o recorte ou a orientacao, e necessario remover explicitamente as marcacoes desta revisao. Elas nao serao reposicionadas automaticamente."
        }
        return result + " A imagem fonte nao sera alterada."
    }

    private func beginWork(_ kind: Work?) -> UInt64 {
        let version = versions.advance()
        worker.invalidate(version)
        work = kind
        return version
    }
    private func accepts(_ version: UInt64) -> Bool { active && versions.accepts(version) }

    func load(page: ScanPage, folder: URL) {
        guard original == nil else { return }
        active = true
        self.folder = folder
        original = page
        draft = page
        cropSnapshot = page
        adjustments = EditorAdjustmentState(page.reconstructedAdjustments)
        let version = beginWork(.loading)
        worker.perform(revision: version, work: {
            let data = try Data(contentsOf: folder.appendingPathComponent(page.sourceFile))
            let source = ScanEngine.normalized(try ScanEngine.image(data), maximum: 1400)
            var copy = page
            let preview = try ScanEngine.recoveredPreview(source: source, page: &copy)
            return (source, preview)
        }, completion: { [weak self] result in
            guard let self, self.accepts(version) else { return }
            self.work = nil
            switch result {
            case .success(let images):
                self.source = images.0; self.preview = images.1; self.previewReady = true
            case .failure(let failure): self.error = failure.localizedDescription
            }
        })
    }
    func stop() {
        active = false
        _ = beginWork(nil)
    }
    private func invalidateText() {
        draft?.lines = []
        draft?.ocrWarning = nil
        recognizedText = ""
        previewReady = false
    }
    func refreshPreview(debounced: Bool = true) {
        guard let source, let page = draft else { return }
        previewReady = false
        let version = beginWork(.preview)
        worker.perform(revision: version, delay: debounced ? 0.22 : 0, work: {
            var copy = page
            return try ScanEngine.recoveredPreview(source: source, page: &copy)
        }, completion: { [weak self] result in
            guard let self, self.accepts(version) else { return }
            self.work = nil
            switch result {
            case .success(let image): self.preview = image; self.previewReady = true
            case .failure(let failure): self.error = failure.localizedDescription
            }
        })
    }
    func setFilter(_ filter: PageFilter) {
        guard stage == .processed, !controlsBlocked, draft?.filter != filter else { return }
        draft?.filter = filter
        invalidateText()
        refreshPreview()
    }
    func beginAdjustments() {
        guard stage == .processed, !controlsBlocked, let page = draft else { return }
        adjustmentSnapshot = page
        adjustmentTextSnapshot = recognizedText
        adjustments = EditorAdjustmentState(page.reconstructedAdjustments)
        adjustments.begin()
        stage = .adjustments
        draft?.reconstructedAdjustments = adjustments.effective
    }
    func selectAdjustment(_ control: EditorAdjustmentState.Control) { adjustments.selected = control }
    func adjust(to value: Double) {
        guard stage == .adjustments, !saving else { return }
        adjustments.set(adjustments.selected, to: value)
        draft?.reconstructedAdjustments = adjustments.effective
        invalidateText()
        refreshPreview()
    }
    func finishAdjustments(confirm: Bool) {
        guard stage == .adjustments, !saving else { return }
        let changed = draft != adjustmentSnapshot
        if confirm {
            adjustments.confirm()
            draft?.reconstructedAdjustments = adjustments.effective
            if draft != adjustmentSnapshot {
                invalidateText()
                refreshPreview(debounced: false)
            } else {
                previewReady = true
            }
        } else {
            adjustments.cancel()
            if let snapshot = adjustmentSnapshot { draft = snapshot }
            recognizedText = adjustmentTextSnapshot
            if changed {
                refreshPreview(debounced: false)
            } else {
                previewReady = true
            }
        }
        adjustmentSnapshot = nil
        adjustmentTextSnapshot = ""
        stage = .processed
    }
    func requestGeometry(_ change: GeometryChange) {
        guard !controlsBlocked else { return }
        if hasOverlays || hasOCR { pendingGeometry = change }
        else { applyGeometry(change) }
    }
    func confirmGeometry() {
        guard let change = pendingGeometry else { return }
        pendingGeometry = nil
        applyGeometry(change)
    }
    private func applyGeometry(_ change: GeometryChange) {
        switch change {
        case .crop:
            cropSnapshot = draft // BEFORE the explicitly approved overlay removal.
            stage = .crop
        case .unlockCrop:
            if cropSnapshot == nil { cropSnapshot = draft }
        default: break
        }
        if hasOverlays { draft?.overlays = [] }
        invalidateText()
        preview = nil
        _ = beginWork(nil)
        switch change {
        case .rotate(let delta):
            let updated = (turns + delta + 4) % 4
            draft?.quarterTurns = updated
            if stage != .crop { refreshPreview(debounced: false) }
        case .detectBorders: detectBorders()
        case .crop, .unlockCrop: break
        }
    }
    func moveCorner(_ index: Int, to point: CGPoint) {
        guard stage == .crop, !hasOverlays, !controlsBlocked else { return }
        let changed = EditorGeometry.replacing(corners, index: index,
            point: EditorGeometry.sourcePoint(point, quarterTurns: turns))
        draft?.corners = changed
        draft?.autoCrop = true
        invalidateText()
        _ = beginWork(nil)
    }
    private func detectBorders() {
        guard let cg = source?.cgImage else { return }
        let version = beginWork(.borders)
        worker.perform(revision: version, work: { try ScanEngine.detectCorners(cg) }, completion: { [weak self] result in
            guard let self, self.accepts(version) else { return }
            self.work = nil
            switch result {
            case .success(let corners):
                if let corners, EditorGeometry.isValid(corners) {
                    self.draft?.corners = corners; self.draft?.autoCrop = true
                    self.notice = "Bordas detectadas. Ajuste os cantos antes de avancar."
                } else { self.notice = "Nenhuma borda confiavel. Ajuste os quatro cantos manualmente." }
            case .failure(let failure): self.error = failure.localizedDescription
            }
        })
    }
    func processCrop() {
        guard stage == .crop, !controlsBlocked else { return }
        guard EditorGeometry.isValid(corners) else {
            error = "Os cantos estao cruzados ou a area e muito pequena. Corrija o quadrilatero."
            return
        }
        let selected = corners
        draft?.corners = selected
        draft?.autoCrop = true
        cropSnapshot = nil
        stage = .processed
        invalidateText()
        refreshPreview(debounced: false)
    }
    func cancelCrop() {
        guard !controlsBlocked, let snapshot = cropSnapshot else { return }
        draft = snapshot
        adjustments = EditorAdjustmentState(snapshot.reconstructedAdjustments)
        cropSnapshot = nil
        stage = .processed
        recognizedText = ""
        refreshPreview(debounced: false)
    }
    func openOverlay(_ mode: EditorSheet) {
        guard stage == .processed, previewReady, !controlsBlocked else { return }
        sheet = mode
    }
    func addOverlays(_ overlays: [PageOverlay]) {
        guard !overlays.isEmpty, stage == .processed, !saving else { return }
        let combined = (draft?.overlays ?? []) + overlays
        draft?.overlays = combined
        invalidateText()
        // Do not keep showing the old unredacted preview during the new render.
        preview = nil
        refreshPreview(debounced: false)
    }
    func recognize() {
        guard stage == .processed, previewReady, !controlsBlocked, let folder, let page = draft else { return }
        recognizedText = ""
        sheet = .ocr
        let version = beginWork(.ocr)
        worker.perform(revision: version, work: {
            // OCR uses the full working image, not the 1400px interactive preview.
            let source = try ScanEngine.image(Data(contentsOf: folder.appendingPathComponent(page.sourceFile)))
            var copy = page
            let rendered = try ScanEngine.recoveredPreview(source: source, page: &copy)
            let lines = try ScanEngine.recognize(rendered)
            return EditorGeometry.visibleOCR(lines, overlays: page.overlays ?? [])
        }, completion: { [weak self] result in
            guard let self, self.accepts(version) else { return }
            self.work = nil
            switch result {
            case .success(let lines):
                self.draft?.lines = lines
                self.recognizedText = lines.map(\.text).joined(separator: "\n")
            case .failure(let failure):
                self.sheet = nil; self.error = failure.localizedDescription
            }
        })
    }
}

// Presentation-only renders. Each copy goes through the existing engine, including
// overlays, and never changes the editor's revision, draft or persistence pipeline.
@MainActor
private final class EditorFilterThumbnails: ObservableObject {
    @Published private(set) var page: ScanPage?
    @Published private(set) var images: [Int: UIImage] = [:]
    private let worker = EditorImageWorker(qos: .utility)
    private var versions = EditorPreviewRevision()

    func render(source: UIImage, page: ScanPage) {
        if self.page == page && !images.isEmpty { return }
        reset()
        let version = versions.current
        let filters = EditorFilterCatalog.recoveredOrder + [.removeShadow]
        worker.perform(revision: version, delay: 0.25, work: {
            let thumbnailSource = ScanEngine.normalized(source, maximum: 160)
            var result: [Int: UIImage] = [:]
            for filter in filters {
                var candidate = page
                candidate.filter = filter
                result[EditorFilterCatalog.nativeModeID(filter)] = try ScanEngine.recoveredPreview(
                    source: thumbnailSource, page: &candidate)
            }
            return result
        }, completion: { [weak self] result in
            guard let self, self.versions.accepts(version) else { return }
            if case .success(let images) = result {
                self.images = images
                self.page = page
            }
            // A thumbnail failure must not block editing or expose the raw source.
        })
    }

    func reset() {
        worker.invalidate(versions.advance())
        page = nil
        images = [:]
    }
}

struct RecoveredPageEditor: View {
    typealias Contract = RecoveredEditorToolbarContract
    private enum ContentMode: Hashable { case image, text }
    @EnvironmentObject private var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    let documentID: UUID
    let pageID: UUID
    @StateObject private var model = EditorViewModel()
    @StateObject private var thumbnails = EditorFilterThumbnails()
    @State private var contentMode: ContentMode = .image
    @State private var discardRequested = false
    @State private var deleteRequested = false

    private var thumbnailRecipe: ScanPage? {
        guard model.stage != .crop, model.source != nil,
              var page = (model.stage == .adjustments ? model.adjustmentSnapshot : nil) ?? model.draft else { return nil }
        // Selecting a filter or completing OCR does not regenerate the whole strip.
        page.filter = .natural
        page.lines = []
        page.ocrWarning = nil
        return page
    }
    private var transcript: String {
        if !model.recognizedText.isEmpty { return model.recognizedText }
        guard let page = model.draft else { return "" }
        return EditorGeometry.visibleOCR(page.lines, overlays: page.overlays ?? [])
            .map(\.text).joined(separator: "\n")
    }
    private var navigationTitle: String {
        if model.stage == .crop { return "Recortar pagina" }
        return store.document(documentID)?.title ?? "Editar pagina"
    }
    private var layout: Contract.Layout {
        switch model.stage {
        case .crop: return .crop
        case .processed: return .processed
        case .adjustments: return .adjustments
        }
    }
    private var selectedOperations: Set<Contract.Operation> {
        guard model.stage == .adjustments else { return [] }
        switch model.adjustments.selected {
        case .contrast: return [.contrast]
        case .brightness: return [.brightness]
        case .detail: return [.detail]
        }
    }
    private var unavailableOperations: Set<Contract.Operation> {
        guard !model.previewReady else { return [] }
        var result: Set<Contract.Operation> = [.textWatermark, .annotation, .signature, .smudgeEditor, .recognizeText]
        if model.stage != .adjustments { result.insert(.done) }
        return result
    }
    var body: some View {
        VStack(spacing: 0) {
            stageHeader
            imageArea
            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(ScannerAppearance.mutedInk)
                    .multilineTextAlignment(.center).padding(8)
            }
        }
        .background(ScannerAppearance.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.screen")
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(ScannerAppearance.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancelar") {
                    if model.hasChanges { discardRequested = true } else { dismiss() }
                }.disabled(model.saving).accessibilityIdentifier("editor.cancel")
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if model.stage == .processed {
                    Button { model.requestGeometry(.crop) } label: {
                        Text("Reprocessar").font(.subheadline)
                    }
                        .accessibilityLabel("Recortar").accessibilityIdentifier("editor.crop")
                        .disabled(model.controlsBlocked || store.isBusy)
                    Button { model.beginAdjustments() } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Ajustes").accessibilityIdentifier("editor.adjustments")
                        .disabled(model.controlsBlocked || store.isBusy)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if model.stage == .processed && contentMode == .image { filterStrip }
                if model.stage == .adjustments { adjustmentPanel }
                Divider()
                EditorNativeToolbar(layout: layout,
                    enabled: !model.controlsBlocked && !store.isBusy && model.source != nil,
                    selected: selectedOperations, disabledOperations: unavailableOperations,
                    onOperation: handle)
                    .frame(height: 50)
            }.background(ScannerAppearance.surface)
        }
        .tint(ScannerAppearance.accent)
        .preferredColorScheme(.light)
        .disabled(model.saving)
        .interactiveDismissDisabled(model.saving || model.hasChanges)
        .task {
            guard let document = store.document(documentID),
                  let page = document.pages.first(where: { $0.id == pageID }) else {
                model.error = "Documento ou pagina nao existe mais. Nenhuma nova pagina foi criada."
                return
            }
            model.load(page: page, folder: store.root.appendingPathComponent(documentID.uuidString))
        }
        .task(id: thumbnailRecipe) {
            guard let page = thumbnailRecipe, let source = model.source else {
                thumbnails.reset()
                return
            }
            thumbnails.render(source: source, page: page)
        }
        .onDisappear { model.stop(); thumbnails.reset() }
        .onChange(of: model.stage) { stage in
            if stage != .processed { contentMode = .image }
        }
        .onChange(of: store.isBusy) { busy in
            if !busy && model.saving {
                // Store clears isBusy before publishing its reload/completion.
                DispatchQueue.main.async { finishSave() }
            }
        }
        .sheet(item: $model.sheet) { sheet in
            if sheet == .ocr {
                EditorOCRTranscript(text: model.recognizedText, busy: model.work == .ocr)
            } else if let image = model.preview {
                EditorOverlayComposer(mode: sheet, image: image, onCommit: model.addOverlays)
            }
        }
        .alert("Nao foi possivel concluir", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
        .confirmationDialog("Reprocessar geometria?", isPresented: Binding(
            get: { model.pendingGeometry != nil }, set: { if !$0 { model.pendingGeometry = nil } }), titleVisibility: .visible) {
                Button(model.hasOverlays ? "Remover marcacoes e continuar" : "Reprocessar",
                       role: model.hasOverlays ? .destructive : nil) { model.confirmGeometry() }
                Button("Cancelar", role: .cancel) { model.pendingGeometry = nil }
            } message: { Text(model.geometryWarning) }
        .confirmationDialog("Descartar alteracoes desta pagina?", isPresented: $discardRequested, titleVisibility: .visible) {
            Button("Descartar e sair", role: .destructive) { dismiss() }
            Button("Continuar editando", role: .cancel) {}
        } message: { Text("O documento salvo e a imagem fonte nao serao modificados.") }
        .confirmationDialog("Remover esta pagina do documento?", isPresented: $deleteRequested, titleVisibility: .visible) {
            Button("Remover pagina", role: .destructive) { deletePage() }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("As alteracoes deste editor serao descartadas. A fonte e preservada pelo armazenamento.") }
    }
    private var stageHeader: some View {
        VStack(spacing: 8) {
            if model.stage == .processed {
                Picker("Conteudo da pagina", selection: $contentMode) {
                    Text("Imagem").tag(ContentMode.image)
                    Text("Texto").tag(ContentMode.text)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 224)
                .accessibilityIdentifier("editor.content-mode")
            }
            let activeWork = model.work == .loading || model.work == .borders || model.work == .ocr
            if model.stage != .processed || model.saving || activeWork {
                HStack(spacing: 8) {
                    Text(model.stage == .crop ? "Recorte" : model.stage == .adjustments ? "Ajustes" : "Previa")
                        .font(.caption.weight(.medium))
                    Spacer()
                    if model.saving {
                        ProgressView().tint(ScannerAppearance.accent)
                        Text("Salvando...").font(.caption)
                    } else if activeWork {
                        ProgressView().tint(ScannerAppearance.accent)
                        Text("Processando...").font(.caption)
                    } else {
                        Text("No dispositivo").font(.caption)
                    }
                }
            }
        }
        .foregroundStyle(ScannerAppearance.mutedInk)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(ScannerAppearance.surface)
    }
    private var imageArea: some View {
        GeometryReader { geometry in
            if model.stage == .crop, let source = model.source {
                let oriented = model.turns % 2 == 0 ? source.size : CGSize(width: source.size.height, height: source.size.width)
                let size = EditorGeometry.fittedSize(oriented,
                    inside: CGSize(width: max(1, geometry.size.width - 24), height: max(1, geometry.size.height - 100)))
                VStack(spacing: 12) {
                    Text(model.hasOverlays ? "Marcacoes existentes: libere o recorte para mover os cantos." : "Arraste os quatro cantos. Avancar aplica a perspectiva.")
                        .font(.caption).foregroundStyle(ScannerAppearance.mutedInk).multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    cropCanvas(source, size: size)
                    HStack {
                        Button("Cancelar recorte") { model.cancelCrop() }
                            .accessibilityIdentifier("editor.cancel-crop")
                        if model.hasOverlays {
                            Button("Liberar recorte") { model.requestGeometry(.unlockCrop) }
                                .accessibilityIdentifier("editor.unlock-crop")
                        }
                    }.font(.caption).disabled(model.controlsBlocked)
                }.frame(width: geometry.size.width, height: geometry.size.height)
            } else if model.stage == .processed && contentMode == .text {
                transcriptArea.frame(width: geometry.size.width, height: geometry.size.height)
            } else if let preview = model.preview {
                Image(uiImage: preview).resizable().scaledToFit().padding(8)
                    .opacity(model.previewReady ? 1 : 0.45)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .accessibilityLabel(model.previewReady ? "Previa da pagina" : "Previa sendo atualizada")
                    .accessibilityIdentifier("editor.preview")
            } else {
                VStack(spacing: 12) {
                    if model.work != nil { ProgressView().tint(ScannerAppearance.accent) }
                    Text(model.work != nil ? "Preparando imagem..." : "Previa indisponivel")
                        .font(.footnote).foregroundStyle(ScannerAppearance.mutedInk)
                    if model.work == nil && model.source != nil {
                        Button("Tentar previa novamente") { model.refreshPreview(debounced: false) }
                    }
                }.frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }
    private var transcriptArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if transcript.isEmpty {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(ScannerAppearance.accent)
                        .accessibilityHidden(true)
                    Text("Texto da pagina").font(.headline)
                    Text("Reconheca o texto para consultar e selecionar o conteudo desta pagina.")
                        .font(.subheadline).foregroundStyle(ScannerAppearance.mutedInk)
                } else {
                    Text(transcript).font(.body).lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let warning = model.draft?.ocrWarning {
                    Text(warning).font(.caption).foregroundStyle(ScannerAppearance.mutedInk)
                }
                Button { model.recognize() } label: {
                    Label(transcript.isEmpty ? "Reconhecer texto" : "Reconhecer novamente", systemImage: "text.viewfinder")
                        .font(.subheadline.weight(.medium)).padding(.vertical, 8)
                }
                .disabled(!model.previewReady || model.controlsBlocked || store.isBusy)
                .accessibilityIdentifier("editor.inline-ocr.recognize")
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ScannerAppearance.surface)
            .padding(8)
        }
        .accessibilityIdentifier("editor.inline-ocr")
    }
    private func cropCanvas(_ image: UIImage, size: CGSize) -> some View {
        let points = EditorGeometry.vertices(model.corners)
        return ZStack {
            Image(uiImage: image).resizable()
                .frame(width: model.turns % 2 == 0 ? size.width : size.height,
                       height: model.turns % 2 == 0 ? size.height : size.width)
                .rotationEffect(.degrees(Double(model.turns) * 90))
            Path { path in
                for (index, corner) in points.enumerated() {
                    let unit = EditorGeometry.displayPoint(corner, quarterTurns: model.turns)
                    let point = CGPoint(x: unit.x * size.width, y: unit.y * size.height)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                path.closeSubpath()
            }.stroke(EditorGeometry.isValid(model.corners) ? ScannerAppearance.accent : Color.red, lineWidth: 2)
            ForEach(0..<4, id: \.self) { index in
                let point = EditorGeometry.displayPoint(points[index], quarterTurns: model.turns)
                Circle().fill(ScannerAppearance.accent).frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
                    .position(x: point.x * size.width, y: point.y * size.height)
                    .accessibilityLabel("Canto \(index + 1)")
                    .accessibilityIdentifier("editor.crop.corner.\(index)")
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("editor-crop"))
                        .onChanged { value in
                            guard size.width > 0, size.height > 0 else { return }
                            model.moveCorner(index, to: CGPoint(x: value.location.x / size.width, y: value.location.y / size.height))
                        })
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "editor-crop")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.crop")
    }
    private var filterStrip: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(EditorFilterCatalog.recoveredOrder) { filter in filterButton(filter) }
                    Divider().frame(height: 72)
                    filterButton(.removeShadow)
                }.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 10)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("editor.filters")
            if model.draft?.filter == .removeShadow {
                Text("* Remocao de sombra independente; nao e o motor original.")
                    .font(.caption2).foregroundStyle(ScannerAppearance.mutedInk)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
        }.disabled(model.controlsBlocked || store.isBusy)
    }
    private func filterButton(_ filter: PageFilter) -> some View {
        let selected = model.draft?.filter == filter
        return Button { model.setFilter(filter) } label: {
            VStack(spacing: 0) {
                ZStack {
                    ScannerAppearance.canvas
                    // Never fall back to source or retain another geometry/overlay recipe.
                    if thumbnails.page == thumbnailRecipe,
                       let image = thumbnails.images[EditorFilterCatalog.nativeModeID(filter)] {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: 72, height: 76).clipped()
                    } else {
                        Image(systemName: "photo").font(.system(size: 22, weight: .light))
                            .foregroundStyle(ScannerAppearance.mutedInk)
                    }
                }
                .frame(width: 72, height: 76)
                .accessibilityHidden(true)
                Text(EditorFilterCatalog.title(filter))
                    .font(.caption2.weight(selected ? .semibold : .regular))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(width: 72, height: 24)
                    .foregroundStyle(selected ? Color.white : ScannerAppearance.mutedInk)
                    .background(selected ? ScannerAppearance.accent : ScannerAppearance.surface)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3)
                .strokeBorder(selected ? ScannerAppearance.accent : ScannerAppearance.mutedInk.opacity(0.18),
                              lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(EditorFilterCatalog.title(filter))
        .accessibilityIdentifier("editor.filter.\(EditorFilterCatalog.nativeModeID(filter))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var adjustmentPanel: some View {
        let control = model.adjustments.selected
        let title = control == .contrast ? "Contraste" : control == .brightness ? "Brilho" : "Detalhe"
        return VStack(spacing: 4) {
            HStack { Text(title); Spacer(); Text("\(Int(model.adjustments.value(control)))").monospacedDigit() }
                .font(.caption).foregroundStyle(ScannerAppearance.mutedInk)
            Slider(value: Binding(get: { model.adjustments.value(control) }, set: { model.adjust(to: $0) }),
                   in: EditorAdjustmentState.range(control), step: 1)
                .accessibilityLabel(title).accessibilityIdentifier("editor.adjustment.slider")
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.adjustments.panel")
    }
    private func handle(_ operation: Contract.Operation) {
        guard !model.controlsBlocked && !store.isBusy else { return }
        let plan = Contract.plan(operation, nativeStatus: model.stage.rawValue, zoomScale: 1,
                                 pageContainsOCR: model.hasOCR)
        switch plan.intent {
        case .deletePage: deleteRequested = true
        case .detectBorders: model.requestGeometry(.detectBorders)
        case .rotateLeft, .rotateProcessedPage: model.requestGeometry(.rotate(-1))
        case .rotateRight: model.requestGeometry(.rotate(1))
        case .clearOCRAndProcessCrop: model.processCrop()
        case .recognizeText: model.recognize()
        case .showAdjustments: model.beginAdjustments()
        case .confirmAdjustments: model.finishAdjustments(confirm: true)
        case .cancelAdjustments: model.finishAdjustments(confirm: false)
        case .savePage: save()
        case .showSignature: model.openOverlay(.signature)
        case .showTextWatermark: model.openOverlay(.text)
        case .smudgePage: model.openOverlay(.redaction)
        case .enterInkNote(let mode): model.openOverlay(mode == 1 ? .redaction : .annotation)
        case .selectAdjustment(let operation):
            model.selectAdjustment(operation == .detail ? .detail : operation == .brightness ? .brightness : .contrast)
        case .retakePhoto, .continueCapture, .addCapture:
            // Unreachable: no pageList/referenceMode 10. Capture belongs to the document screen.
            break
        case .noAction: break
        }
    }
    private func save() {
        guard model.stage == .processed, model.previewReady, !store.isBusy, !model.saving,
              let draft = model.draft, let original = model.original,
              let document = store.document(documentID),
              let current = document.pages.first(where: { $0.id == pageID }) else { return }
        guard draft.id == pageID, current == original, draft.sourceFile == original.sourceFile else {
            model.error = "A pagina mudou fora deste editor. Saia e reabra antes de salvar; nada foi sobrescrito."
            return
        }
        model.saving = true
        // Store owns persistence and OCR. This editor never writes images or manifests.
        store.revise(document: document, page: draft)
    }
    private func finishSave() {
        guard model.saving, !store.isBusy else { return }
        model.saving = false
        if let error = store.error { model.error = error; return }
        guard let saved = store.document(documentID)?.pages.first(where: { $0.id == pageID }),
              saved.sourceFile == model.original?.sourceFile,
              saved.renderedFile != model.original?.renderedFile else {
            model.error = "O armazenamento nao confirmou uma nova revisao. Reabra o documento antes de tentar novamente."
            return
        }
        dismiss()
    }
    private func deletePage() {
        guard !store.isBusy, let document = store.document(documentID),
              let index = document.pages.firstIndex(where: { $0.id == pageID }),
              document.pages[index] == model.original else {
            model.error = "A pagina mudou; a remocao foi cancelada."
            return
        }
        store.removePages(document, at: IndexSet(integer: index))
        if store.document(documentID)?.pages.contains(where: { $0.id == pageID }) == false { dismiss() }
        else { model.error = store.error ?? "O armazenamento nao confirmou a remocao." }
    }
}
