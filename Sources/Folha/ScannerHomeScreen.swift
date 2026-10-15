import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

private enum HomeTab: String, CaseIterable {
    case home = "Inicio", files = "Arquivos", tools = "Ferramentas", me = "Eu"
    var title: String {
        switch self {
        case .home: return "Início"
        case .files: return "Arquivos"
        case .tools: return "Ferramentas"
        case .me: return "Eu"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .files: return "folder.fill"
        case .tools: return "square.grid.2x2.fill"
        case .me: return "person.fill"
        }
    }
}

private enum HomeTool: String, CaseIterable, Identifiable {
    case scan = "Digitalizar", photos = "Importar fotos", files = "Importar arquivos", pdf = "PDF"
    case text = "Extrair texto", signature = "Assinatura", filters = "Filtros", all = "Todas"
    var id: String { rawValue }
    var displayTitle: String {
        switch self {
        case .scan: return "Digitalizar"
        case .photos: return "Importar imagens"
        case .files: return "Importar arquivos"
        case .pdf: return "Ferramentas PDF"
        case .text: return "Extrair texto"
        case .signature: return "Assinatura / ID"
        case .filters: return "Cor Mágica"
        case .all: return "Tudo"
        }
    }
    var symbol: String {
        switch self {
        case .scan: return "viewfinder"
        case .photos: return "photo.on.rectangle"
        case .files: return "folder.badge.plus"
        case .pdf: return "doc.richtext.fill"
        case .text: return "text.viewfinder"
        case .signature: return "signature"
        case .filters: return "wand.and.stars"
        case .all: return "square.grid.2x2.fill"
        }
    }
    var color: Color {
        switch self {
        case .scan: return ScannerAppearance.accent
        case .pdf: return Color(red: 0.97, green: 0.31, blue: 0.23)
        case .photos: return Color(red: 0.18, green: 0.52, blue: 0.96)
        case .files: return Color(red: 0.96, green: 0.62, blue: 0.04)
        case .text: return Color(red: 0.02, green: 0.71, blue: 0.83)
        case .signature: return Color(red: 0.06, green: 0.73, blue: 0.51)
        case .filters: return Color(red: 0.55, green: 0.36, blue: 0.96)
        case .all: return ScannerAppearance.accent
        }
    }
}

enum ScannerRoute: Hashable {
    case document(UUID, startWithText: Bool)
    case pageEditor(documentID: UUID, pageID: UUID)
}

private enum DocumentQuickAction: Identifiable {
    case toWord
    case toExcel
    case ocrText
    case openEditor
    case exportPDF

    var id: String {
        switch self {
        case .toWord: return "toWord"
        case .toExcel: return "toExcel"
        case .ocrText: return "ocrText"
        case .openEditor: return "openEditor"
        case .exportPDF: return "exportPDF"
        }
    }

    var title: String {
        switch self {
        case .toWord: return "Converter para Word (.doc)"
        case .toExcel: return "Converter para Excel (.csv)"
        case .ocrText: return "Extrair Texto (OCR)"
        case .openEditor: return "Assinar / Filtros Cor Mágica"
        case .exportPDF: return "Ferramentas PDF"
        }
    }
}

struct ScannerHomeScreen: View {
    @EnvironmentObject private var store: DocumentStore
    @State private var tab: HomeTab = .home
    @State private var search = ""
    @State private var path: [ScannerRoute] = []
    @State private var camera = false
    @State private var cameraWorkflow: CameraWorkflowMode = .scan
    @State private var photoPicker = false
    @State private var filePicker = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var working = false
    @State private var grid = false
    @State private var alphabetical = false
    @State private var selected: Set<UUID> = []
    @State private var tool: HomeTool?
    @State private var pendingQuickAction: DocumentQuickAction?
    @State private var share: ExportFileSet?
    @State private var quickPreview: SharedFile?

    private var documents: [ScanDocument] {
        let matches = store.documents.filter {
            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
                || DocumentTransfer.visibleText(document: $0).localizedCaseInsensitiveContains(search)
        }
        return alphabetical ? matches.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                            : matches.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if tab == .me {
                    about
                } else {
                    searchField
                    ScrollView {
                        VStack(spacing: 22) {
                            if tab == .home || tab == .tools {
                                toolGrid
                            }
                            if tab == .tools {
                                camScannerToolsHub
                            } else {
                                if tab == .files {
                                    filesTopActionRow
                                }
                                documentLibrary
                            }
                            if !store.storageWarnings.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("Documentos preservados: revisar", systemImage: "exclamationmark.triangle")
                                    ForEach(store.storageWarnings, id: \.self) { Text($0).font(.caption) }
                                }
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .padding(.bottom, 28)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .background(ScannerAppearance.darkCanvas)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library.screen")
            .navigationTitle("CamScanner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if path.isEmpty { bottomBar }
            }
            .navigationDestination(for: ScannerRoute.self) { route in
                switch route {
                case .document(let id, let startWithText):
                    ScannerDocumentScreen(id: id, startWithText: startWithText) { pageID in
                        path.append(.pageEditor(documentID: id, pageID: pageID))
                    }
                case .pageEditor(let documentID, let pageID):
                    RecoveredPageEditor(documentID: documentID, pageID: pageID)
                }
            }
            .fullScreenCover(isPresented: $camera) {
                NativeCameraSheet(
                    initialWorkflow: cameraWorkflow,
                    onFinishPages: { captured, mode in
                        camera = false
                        let inputs = captured.map {
                            ScanInput.scannedPage($0.data, corners: $0.corners, filter: $0.filter, autoCrop: $0.autoCrop)
                        }
                        store.create(inputs: inputs) { created in
                            handlePostCameraNavigation(document: created, mode: mode)
                        }
                    },
                    onFinish: { bytes in
                        camera = false
                        store.create(inputs: bytes.map { ScanInput.scannedPage($0, corners: nil, filter: .clean, autoCrop: true) }) { created in
                            handlePostCameraNavigation(document: created, mode: .scan)
                        }
                    },
                    onCancel: { camera = false },
                    onError: { camera = false; store.error = $0 }
                )
                .ignoresSafeArea()
            }
            .photosPicker(isPresented: $photoPicker, selection: $photos, maxSelectionCount: 50, matching: .images)
            .onChange(of: photos) { _, values in
                guard !values.isEmpty, !working else { return }
                working = true
                Task { @MainActor in
                    defer { working = false; photos = [] }
                    do {
                        let loaded = try await loadScannerPhotos(values)
                        store.create(inputs: loaded) { created in
                            path.append(.document(created.id, startWithText: false))
                            if let firstPage = created.pages.first {
                                path.append(.pageEditor(documentID: created.id, pageID: firstPage.id))
                            }
                        }
                    } catch {
                        store.error = error.localizedDescription
                    }
                }
            }
            .fileImporter(isPresented: $filePicker, allowedContentTypes: [.pdf, .image]) { result in
                guard !working else { return }
                working = true
                Task { @MainActor in
                    defer { working = false }
                    do {
                        store.create(inputs: try await DocumentTransfer.importFile(result.get())) { created in
                            path.append(.document(created.id, startWithText: false))
                        }
                    } catch {
                        store.error = error.localizedDescription
                    }
                }
            }
            .sheet(item: $tool) { chosen in toolChooser(chosen) }
            .sheet(item: $pendingQuickAction) { action in quickActionChooser(action) }
            .sheet(item: $share) { ScannerActivitySheet(urls: $0.urls) }
            .sheet(item: $quickPreview) { file in
                NavigationStack {
                    PDFPreview(url: file.url)
                        .accessibilityIdentifier("pdf.preview")
                        .navigationTitle("Visualizar PDF")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("Fechar") { quickPreview = nil } }
                }
            }
            .disabled(working || store.isBusy)
            .overlay { if working { ScannerProgress(message: "Processando documento...") } }
        }
    }

    private func handlePostCameraNavigation(document: ScanDocument, mode: CameraWorkflowMode) {
        switch mode {
        case .ocr:
            path.append(.document(document.id, startWithText: true))
        case .toWord:
            path.append(.document(document.id, startWithText: false))
            exportDocumentToWord(document)
        case .toExcel:
            path.append(.document(document.id, startWithText: false))
            exportDocumentToExcel(document)
        default:
            path.append(.document(document.id, startWithText: false))
            if let firstPage = document.pages.first {
                path.append(.pageEditor(documentID: document.id, pageID: firstPage.id))
            }
        }
    }

    // MARK: - Top Search Bar & VIP Badge

    private var searchField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(ScannerAppearance.darkMuted)
                ScannerSearchField(text: $search)
                    .frame(height: 28)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(ScannerAppearance.darkMuted)
                    }
                    .accessibilityLabel("Limpar pesquisa")
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 40)
            .background(ScannerAppearance.darkSurface, in: Capsule())

            HStack(spacing: 4) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 12, weight: .bold))
                Text("PRO")
                    .font(.system(size: 11, weight: .heavy))
            }
            .foregroundStyle(Color.black)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(ScannerAppearance.vipGold, in: Capsule())
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: - 2x4 CamScanner Tool Grid

    private var toolGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 18) {
            ForEach(HomeTool.allCases) { item in
                Button { activate(item) } label: {
                    VStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(item.color.opacity(0.18))
                                .frame(width: 52, height: 52)
                            Image(systemName: item.symbol)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(item.color)
                        }
                        Text(item.displayTitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ScannerAppearance.darkInk)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(height: 28, alignment: .top)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.rawValue)
                .accessibilityIdentifier("library.tool.\(item.id)")
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Files Tab Action Cards

    private var filesTopActionRow: some View {
        HStack(spacing: 10) {
            filesQuickCard(title: "Imp. Arq.", icon: "folder.fill.badge.plus", color: .orange) {
                filePicker = true
            }
            filesQuickCard(title: "Importar imagens", icon: "photo.on.rectangle.angled", color: .blue) {
                photoPicker = true
            }
            filesQuickCard(title: "Auto-Scan", icon: "doc.viewfinder.fill", color: ScannerAppearance.accent) {
                cameraWorkflow = .scan
                camera = true
            }
        }
    }

    private func filesQuickCard(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ScannerAppearance.darkInk)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ScannerAppearance.darkSurface, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Document Library (Recentes & Todos os Documentos)

    private var documentLibrary: some View {
        VStack(spacing: 14) {
            HStack {
                Text(tab == .home ? "Recentes" : "Todos os documentos (\(documents.count))")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(ScannerAppearance.darkInk)
                Spacer()
                if tab == .home {
                    Button { tab = .files } label: {
                        HStack(spacing: 4) {
                            Text("Exibir tudo")
                            Image(systemName: "chevron.right")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ScannerAppearance.darkMuted)
                    }
                } else {
                    Menu {
                        Button("Mais recentes", systemImage: "clock") { alphabetical = false }
                        Button("Nome (A-Z)", systemImage: "textformat.abc") { alphabetical = true }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .foregroundStyle(ScannerAppearance.darkInk)
                    }
                    .accessibilityLabel("Ordenar documentos")

                    Button { grid.toggle() } label: {
                        Image(systemName: grid ? "list.bullet" : "square.grid.2x2")
                            .foregroundStyle(ScannerAppearance.darkInk)
                    }
                    .accessibilityLabel("Alternar lista e grade")
                    .padding(.leading, 10)
                }
            }

            if documents.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "doc.viewfinder.fill")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(ScannerAppearance.accent)
                    Text(search.isEmpty ? "Digitalize seu primeiro documento" : "Nenhum resultado encontrado")
                        .font(.headline)
                        .foregroundStyle(ScannerAppearance.darkInk)
                    Text(search.isEmpty
                         ? "Detecção automática de bordas, recorte de perspectiva, Cor Mágica e OCR local."
                         : "Tente pesquisar por outro título ou palavra reconhecida no texto.")
                        .font(.subheadline)
                        .foregroundStyle(ScannerAppearance.darkMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .padding(.horizontal, 16)
                .background(ScannerAppearance.darkSurface, in: RoundedRectangle(cornerRadius: 16))
            } else if grid && tab == .files {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ForEach(documents) { document in
                        Button {
                            path.append(.document(document.id, startWithText: false))
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                ScannerThumbnail(document: document, width: 115, height: 152)
                                    .frame(maxWidth: .infinity)
                                Text(document.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(ScannerAppearance.darkInk)
                                    .lineLimit(2)
                                Text("\(document.pages.count) paginas")
                                    .font(.caption)
                                    .foregroundStyle(ScannerAppearance.darkMuted)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(ScannerAppearance.darkSurface, in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(document.title), \(document.pages.count) paginas")
                        .accessibilityIdentifier("library.document")
                    }
                }
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(documents) { document in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                Button {
                                    path.append(.document(document.id, startWithText: false))
                                } label: {
                                    HStack(spacing: 13) {
                                        ScannerThumbnail(document: document)
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(document.title)
                                                .font(.system(size: 15, weight: .semibold))
                                                .foregroundStyle(ScannerAppearance.darkInk)
                                                .lineLimit(2)
                                            HStack(spacing: 8) {
                                                Text(document.updatedAt.formatted(date: .numeric, time: .shortened))
                                                Label("\(document.pages.count)", systemImage: "doc.fill")
                                                if !document.searchableText.isEmpty {
                                                    Text("OCR")
                                                        .font(.system(size: 9, weight: .bold))
                                                        .padding(.horizontal, 5)
                                                        .padding(.vertical, 2)
                                                        .background(ScannerAppearance.accent.opacity(0.22), in: RoundedRectangle(cornerRadius: 4))
                                                        .foregroundStyle(ScannerAppearance.accent)
                                                }
                                            }
                                            .font(.system(size: 11))
                                            .foregroundStyle(ScannerAppearance.darkMuted)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(document.title), \(document.pages.count) paginas")
                                .accessibilityIdentifier("library.document")

                                Button {
                                    if selected.contains(document.id) { selected.remove(document.id) }
                                    else { selected.insert(document.id) }
                                } label: {
                                    Image(systemName: selected.contains(document.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20))
                                        .foregroundStyle(selected.contains(document.id) ? ScannerAppearance.accent : ScannerAppearance.darkMuted)
                                        .frame(width: 34, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Selecionar \(document.title)")
                                .accessibilityIdentifier("library.select")
                            }

                            // CamScanner Quick Action Pills (Compartilhar | Para Word | Excel | Visualizar)
                            HStack(spacing: 8) {
                                quickCardPill("Compartilhar", icon: "square.and.arrow.up") {
                                    exportSinglePDF(document)
                                }
                                quickCardPill("Para Word", icon: "doc.text.fill", accent: true) {
                                    exportDocumentToWord(document)
                                }
                                quickCardPill("Excel", icon: "tablecells.fill") {
                                    exportDocumentToExcel(document)
                                }
                                quickCardPill("Visualizar", icon: "eye.fill") {
                                    store.export(document, searchable: true) { quickPreview = SharedFile(url: $0) }
                                }
                            }
                        }
                        .padding(12)
                        .background(ScannerAppearance.darkSurface, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }
    }

    private func quickCardPill(_ title: String, icon: String, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(accent ? ScannerAppearance.accent : ScannerAppearance.darkInk)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(ScannerAppearance.darkElevated, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - CamScanner 7.27 Categorized Tools Hub

    private var camScannerToolsHub: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(ScannerAppearance.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("CS AI • Scanner Inteligente")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(ScannerAppearance.darkInk)
                    Text("Detecção automática de página, Cor Mágica, OCR, Word e Excel no iPhone")
                        .font(.caption)
                        .foregroundStyle(ScannerAppearance.darkMuted)
                }
                Spacer()
            }
            .padding(14)
            .background(ScannerAppearance.darkSurface, in: RoundedRectangle(cornerRadius: 14))

            toolSection("Digitalização Inteligente", items: [
                ("Auto-Scan com Recorte", "viewfinder.circle.fill", ScannerAppearance.accent, {
                    cameraWorkflow = .scan; camera = true
                }),
                ("Cartões ID (RG/CNH)", "person.text.rectangle.fill", Color.blue, {
                    cameraWorkflow = .idCard; camera = true
                }),
                ("Carimbo de Data/Hora", "clock.badge.checkmark.fill", Color.orange, {
                    cameraWorkflow = .timestamp; camera = true
                }),
                ("Leitor de QR Code", "qrcode.viewfinder", Color.purple, {
                    cameraWorkflow = .qrCode; camera = true
                })
            ])

            toolSection("Converter e Extrair (OCR)", items: [
                ("Para Word (.doc)", "doc.richtext.fill", Color.blue, {
                    if documents.isEmpty { cameraWorkflow = .toWord; camera = true }
                    else { pendingQuickAction = .toWord }
                }),
                ("Para Excel (.csv)", "tablecells.fill", Color.green, {
                    if documents.isEmpty { cameraWorkflow = .toExcel; camera = true }
                    else { pendingQuickAction = .toExcel }
                }),
                ("Extrair Texto", "text.viewfinder", Color.cyan, {
                    if documents.isEmpty { cameraWorkflow = .ocr; camera = true }
                    else { pendingQuickAction = .ocrText }
                }),
                ("Assinar / Cor Mágica", "signature", ScannerAppearance.accent, {
                    if documents.isEmpty { cameraWorkflow = .signature; camera = true }
                    else { pendingQuickAction = .openEditor }
                })
            ])
        }
    }

    private func toolSection(_ title: String, items: [(String, String, Color, () -> Void)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(ScannerAppearance.darkInk)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Button(action: item.3) {
                        HStack(spacing: 10) {
                            Image(systemName: item.1)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(item.2)
                                .frame(width: 32, height: 32)
                                .background(item.2.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                            Text(item.0)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(ScannerAppearance.darkInk)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(11)
                        .background(ScannerAppearance.darkSurface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.white.opacity(0.08))
            if !selected.isEmpty {
                HStack(spacing: 14) {
                    Button("Cancelar") { selected.removeAll() }
                        .foregroundStyle(ScannerAppearance.darkInk)
                    Spacer()
                    Text("\(selected.count) selecionados")
                        .font(.caption)
                        .foregroundStyle(ScannerAppearance.darkMuted)
                    Spacer()
                    if selected.count > 1 {
                        Button("Mesclar PDF") { mergeSelected() }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ScannerAppearance.accent)
                            .accessibilityIdentifier("library.mergeSelected")
                    }
                    Button { shareSelected() } label: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(ScannerAppearance.accent)
                    }
                    .accessibilityLabel("Compartilhar PDFs selecionados")
                    .accessibilityIdentifier("library.shareSelected")
                }
                .padding(.horizontal, 22)
                .frame(height: 62)
            } else {
                HStack(spacing: 0) {
                    tabButton(.home)
                    tabButton(.files)
                    Button {
                        cameraWorkflow = .scan
                        camera = true
                    } label: {
                        ZStack {
                            Circle()
                                .fill(ScannerAppearance.accent)
                                .frame(width: 56, height: 56)
                                .shadow(color: ScannerAppearance.accent.opacity(0.45), radius: 8, y: 3)
                            Image(systemName: "camera.fill")
                                .font(.system(size: 23, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .accessibilityLabel("Digitalizar")
                    .accessibilityIdentifier("library.scan")
                    .frame(maxWidth: .infinity)
                    tabButton(.tools)
                    tabButton(.me)
                }
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
        }
        .background(ScannerAppearance.darkSurface)
    }

    private func tabButton(_ item: HomeTab) -> some View {
        Button { tab = item; selected.removeAll() } label: {
            VStack(spacing: 5) {
                Image(systemName: item.symbol).font(.system(size: 18))
                Text(item.title).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(tab == item ? ScannerAppearance.accent : ScannerAppearance.darkMuted)
            .frame(maxWidth: .infinity)
            .frame(height: 55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.tab.\(item.rawValue)")
    }

    // MARK: - Profile / VIP Tab ("Eu")

    private var about: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(ScannerAppearance.accent)
                            .frame(width: 58, height: 58)
                        Text("CS")
                            .font(.system(size: 24, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("CamScanner Pro")
                                .font(.title3.bold())
                                .foregroundStyle(ScannerAppearance.darkInk)
                            Text("VIP")
                                .font(.caption2.weight(.heavy))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(ScannerAppearance.vipGold, in: Capsule())
                                .foregroundStyle(.black)
                        }
                        Text("v0.5.0 • Todos os recursos desbloqueados no iPhone")
                            .font(.caption)
                            .foregroundStyle(ScannerAppearance.darkMuted)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ScannerAppearance.darkSurface, in: RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 12) {
                    Text("Meus Privilégios Ativos")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(ScannerAppearance.vipGold)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        privilegeBadge("Auto-Bordas", icon: "viewfinder")
                        privilegeBadge("Cor Mágica", icon: "wand.and.stars")
                        privilegeBadge("OCR Pro", icon: "text.viewfinder")
                        privilegeBadge("Word/Excel", icon: "tablecells")
                    }
                }
                .padding(16)
                .background(ScannerAppearance.darkSurface, in: RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 10) {
                    Label("\(store.documents.count) documento(s) armazenados localmente", systemImage: "internaldrive.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ScannerAppearance.darkInk)
                    Text("• Detecção automática de página em tempo real com disparo automático (Auto-Shutter) e correção de perspectiva.")
                        .font(.footnote)
                        .foregroundStyle(ScannerAppearance.darkMuted)
                    Text("• Filtro Cor Mágica com remoção adaptativa de sombras e clareamento de papel.")
                        .font(.footnote)
                        .foregroundStyle(ScannerAppearance.darkMuted)
                    Text("• Exportação direta para PDF pesquisável (A4/Letter/Legal), Word (.doc), Excel (.csv), JPG e TXT.")
                        .font(.footnote)
                        .foregroundStyle(ScannerAppearance.darkMuted)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ScannerAppearance.darkSurface, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(20)
        }
    }

    private func privilegeBadge(_ title: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(ScannerAppearance.vipGold)
                .frame(width: 40, height: 40)
                .background(ScannerAppearance.vipGold.opacity(0.14), in: Circle())
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ScannerAppearance.darkInk)
                .lineLimit(1)
        }
    }

    // MARK: - Choosers & Export Helpers

    private func toolChooser(_ chosen: HomeTool) -> some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        tool = nil
                        cameraWorkflow = chosen == .text ? .ocr : chosen == .signature ? .signature : .scan
                        camera = true
                    } label: {
                        Label("Digitalizar novo documento com a câmera", systemImage: "camera.fill")
                            .foregroundStyle(ScannerAppearance.accent)
                    }
                    ForEach(documents) { document in
                        Button {
                            let openText = chosen == .text
                            let openEditor = chosen == .signature || chosen == .filters
                            tool = nil
                            path.append(.document(document.id, startWithText: openText))
                            if openEditor, let firstPage = document.pages.first {
                                path.append(.pageEditor(documentID: document.id, pageID: firstPage.id))
                            }
                        } label: {
                            HStack(spacing: 14) {
                                ScannerThumbnail(document: document)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(document.title).foregroundStyle(.primary)
                                    Text("\(document.pages.count) página(s)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: { Text("Escolha um documento ou digitalize") }
            }
            .navigationTitle(chosen.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { tool = nil } }
            }
        }
    }

    private func quickActionChooser(_ action: DocumentQuickAction) -> some View {
        NavigationStack {
            List {
                Section("Selecione o documento") {
                    ForEach(documents) { document in
                        Button {
                            pendingQuickAction = nil
                            switch action {
                            case .toWord:
                                exportDocumentToWord(document)
                            case .toExcel:
                                exportDocumentToExcel(document)
                            case .ocrText:
                                path.append(.document(document.id, startWithText: true))
                            case .openEditor:
                                path.append(.document(document.id, startWithText: false))
                                if let first = document.pages.first {
                                    path.append(.pageEditor(documentID: document.id, pageID: first.id))
                                }
                            case .exportPDF:
                                exportSinglePDF(document)
                            }
                        } label: {
                            HStack(spacing: 14) {
                                ScannerThumbnail(document: document)
                                Text(document.title).foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(action.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { pendingQuickAction = nil } }
            }
        }
    }

    private func activate(_ item: HomeTool) {
        switch item {
        case .scan:
            cameraWorkflow = .scan
            camera = true
        case .photos:
            photoPicker = true
        case .files:
            filePicker = true
        case .all:
            tab = .tools
        default:
            tool = item
        }
    }

    private func exportSinglePDF(_ document: ScanDocument) {
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                let url = try await DocumentTransfer.exportConfiguredPDF(document: document, root: store.root, searchable: true)
                share = ExportFileSet(urls: [url])
            } catch {
                store.error = error.localizedDescription
            }
        }
    }

    private func exportDocumentToWord(_ document: ScanDocument) {
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                let url = try await DocumentTransfer.exportWord(document: document, root: store.root)
                share = ExportFileSet(urls: [url])
            } catch {
                store.error = error.localizedDescription
            }
        }
    }

    private func exportDocumentToExcel(_ document: ScanDocument) {
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                let url = try await DocumentTransfer.exportExcelCSV(document: document, root: store.root)
                share = ExportFileSet(urls: [url])
            } catch {
                store.error = error.localizedDescription
            }
        }
    }

    private func shareSelected() {
        let chosen = documents.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            do { share = ExportFileSet(urls: try await DocumentTransfer.exportPDFs(documents: chosen, root: store.root, searchable: true)) }
            catch { store.error = error.localizedDescription }
        }
    }

    private func mergeSelected() {
        let chosen = documents.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            do { share = ExportFileSet(urls: [try await DocumentTransfer.mergePDF(documents: chosen, root: store.root, searchable: true)]) }
            catch { store.error = error.localizedDescription }
        }
    }
}

private struct ScannerThumbnail: View {
    @EnvironmentObject private var store: DocumentStore
    let document: ScanDocument
    var width: CGFloat = 58
    var height: CGFloat = 76
    var body: some View {
        Group {
            if let page = document.pages.first, let image = store.pageImage(page, in: document, thumbnail: true) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.14)))
    }
}

struct ScannerDocumentScreen: View {
    @EnvironmentObject private var store: DocumentStore
    let id: UUID
    var startWithText = false
    var onOpenPage: ((UUID) -> Void)? = nil
    @State private var textMode = false
    @State private var reordering = false
    @State private var rename = false
    @State private var title = ""
    @State private var camera = false
    @State private var replacement: UUID?
    @State private var photos: [PhotosPickerItem] = []
    @State private var photoPicker = false
    @State private var filePicker = false
    @State private var importing = false
    @State private var preview: SharedFile?
    @State private var export = false
    @State private var add = false
    @State private var fallbackPageID: UUID?

    var body: some View {
        Group {
            if let document = store.document(id) {
                List {
                    Section {
                        Picker("Conteudo", selection: $textMode) {
                            Text("Imagem").tag(false)
                            Text("Texto (OCR)").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .padding(.vertical, 3)
                    }
                    .listRowBackground(ScannerAppearance.surface)
                    .listRowSeparator(.hidden)

                    if textMode {
                        Section {
                            let text = DocumentTransfer.visibleText(document: document)
                            Text(text.isEmpty ? "Nenhum texto reconhecido." : text)
                                .textSelection(.enabled)
                                .font(.body)
                                .padding(.vertical, 16)
                                .accessibilityIdentifier("document.text")
                        }
                        .listRowBackground(ScannerAppearance.surface)
                    } else if reordering {
                        Section("Arraste para ordenar; deslize para remover") {
                            ForEach(Array(document.pages.enumerated()), id: \.element.id) { index, page in
                                HStack {
                                    pageImage(page, document: document).frame(width: 45, height: 60)
                                    Text("Pagina \(index + 1)")
                                }
                            }
                            .onMove { store.movePages(document, from: $0, to: $1) }
                            .onDelete { store.removePages(document, at: $0) }
                        }
                        .environment(\.editMode, .constant(.active))
                    } else {
                        Section {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 18) {
                                ForEach(Array(document.pages.enumerated()), id: \.element.id) { index, page in
                                    Button {
                                        if let onOpenPage { onOpenPage(page.id) }
                                        else { fallbackPageID = page.id }
                                    } label: {
                                        VStack(spacing: 8) {
                                            pageImage(page, document: document)
                                                .frame(height: 200)
                                                .frame(maxWidth: .infinity)
                                                .background(ScannerAppearance.surface)
                                                .overlay(Rectangle().stroke(Color.gray.opacity(0.14)))
                                            HStack {
                                                Text("\(index + 1)").font(.caption.weight(.semibold))
                                                Spacer()
                                                Text(page.filter.title).font(.caption2).foregroundStyle(.secondary)
                                            }
                                        }
                                        .foregroundStyle(.primary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("document.page")
                                    .contextMenu {
                                        Button("Refazer captura", systemImage: "camera.rotate") {
                                            replacement = page.id
                                            camera = true
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 10)
                        }
                        .listRowBackground(ScannerAppearance.canvas)
                        .listRowSeparator(.hidden)
                    }

                    Section {
                        Text("\(document.pages.count) paginas").font(.caption).foregroundStyle(.secondary)
                        ForEach(document.pages.filter { $0.ocrWarning != nil }) {
                            Text($0.ocrWarning ?? "").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .listRowBackground(ScannerAppearance.canvas)
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(ScannerAppearance.canvas)
                .accessibilityIdentifier("document.screen")
                .navigationTitle(document.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .navigationDestination(item: $fallbackPageID) { pageID in
                    RecoveredPageEditor(documentID: id, pageID: pageID)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { title = document.title; rename = true } label: { Image(systemName: "pencil") }
                            .accessibilityLabel("Renomear")
                            .accessibilityIdentifier("document.rename")
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    HStack {
                        footerButton("Adicionar", icon: "plus") { add = true }
                        footerButton(reordering ? "Concluir" : "Ordenar", icon: reordering ? "checkmark" : "square.grid.2x2") {
                            reordering.toggle()
                            textMode = false
                        }
                        footerButton("PDF", icon: "doc.richtext") {
                            store.export(document, searchable: true) { preview = SharedFile(url: $0) }
                        }
                        .accessibilityIdentifier("document.previewPDF")
                        .disabled(document.pages.isEmpty)

                        footerButton("Compartilhar", icon: "square.and.arrow.up") { export = true }
                            .accessibilityIdentifier("document.share")
                            .disabled(document.pages.isEmpty)
                    }
                    .padding(.vertical, 10)
                    .background(ScannerAppearance.surface)
                    .overlay(alignment: .top) { Divider() }
                }
                .alert("Renomear documento", isPresented: $rename) {
                    TextField("Nome", text: $title).accessibilityIdentifier("document.renameField")
                    Button("Cancelar", role: .cancel) { }
                    Button("Salvar") { store.rename(document, to: title) }
                }
                .confirmationDialog("Adicionar paginas", isPresented: $add, titleVisibility: .visible) {
                    Button("Camera") { replacement = nil; camera = true }
                    Button("Fotos") { photoPicker = true }
                    Button("PDF ou imagem do Arquivos") { filePicker = true }
                }
                .disabled(store.isBusy || importing)
                .photosPicker(isPresented: $photoPicker, selection: $photos, maxSelectionCount: 50, matching: .images)
                .onChange(of: photos) { _, values in
                    guard !values.isEmpty, !importing else { return }
                    importing = true
                    Task { @MainActor in
                        defer { importing = false; photos = [] }
                        do { store.append(inputs: try await loadScannerPhotos(values), to: document) }
                        catch { store.error = error.localizedDescription }
                    }
                }
                .fileImporter(isPresented: $filePicker, allowedContentTypes: [.pdf, .image]) { result in
                    guard !importing else { return }
                    importing = true
                    Task { @MainActor in
                        defer { importing = false }
                        do { store.append(inputs: try await DocumentTransfer.importFile(result.get()), to: document) }
                        catch { store.error = error.localizedDescription }
                    }
                }
                .fullScreenCover(isPresented: $camera) {
                    NativeCameraSheet(
                        singleOnly: replacement != nil,
                        onFinishPages: { captured, _ in
                            camera = false
                            if let pageID = replacement, let first = captured.first {
                                store.replace(
                                    input: .scannedPage(first.data, corners: first.corners, filter: first.filter, autoCrop: first.autoCrop),
                                    in: document,
                                    pageID: pageID
                                )
                            } else {
                                let inputs = captured.map {
                                    ScanInput.scannedPage($0.data, corners: $0.corners, filter: $0.filter, autoCrop: $0.autoCrop)
                                }
                                store.append(inputs: inputs, to: document)
                            }
                            replacement = nil
                        },
                        onFinish: { bytes in
                            camera = false
                            if let pageID = replacement, let data = bytes.first {
                                store.replace(input: .scannedPage(data, corners: nil, filter: .clean, autoCrop: true), in: document, pageID: pageID)
                            } else {
                                store.append(inputs: bytes.map { ScanInput.scannedPage($0, corners: nil, filter: .clean, autoCrop: true) }, to: document)
                            }
                            replacement = nil
                        },
                        onCancel: { camera = false; replacement = nil },
                        onError: { camera = false; replacement = nil; store.error = $0 }
                    )
                    .ignoresSafeArea()
                }
                .sheet(item: $preview) { file in
                    NavigationStack {
                        PDFPreview(url: file.url)
                            .accessibilityIdentifier("pdf.preview")
                            .navigationTitle("PDF - \(document.pages.count) paginas")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { Button("Fechar") { preview = nil } }
                    }
                }
                .sheet(isPresented: $export) {
                    ScannerExportSheet(document: document).environmentObject(store)
                }
                .overlay { if importing { ScannerProgress(message: "Importando paginas...") } }
                .onAppear { if startWithText { textMode = true } }
            } else {
                ContentUnavailableView("Documento indisponivel", systemImage: "doc.questionmark")
            }
        }
    }

    private func pageImage(_ page: ScanPage, document: ScanDocument) -> some View {
        Group {
            if let image = store.pageImage(page, in: document, thumbnail: true) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "doc.questionmark").foregroundStyle(.secondary)
            }
        }
    }

    private func footerButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 21))
                Text(title).font(.system(size: 10))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ScannerExportSheet: View {
    @EnvironmentObject private var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    let document: ScanDocument
    @State private var searchable = true
    @State private var pageSize: DocumentTransfer.PDFPageSize = .a4
    @State private var orientation: DocumentTransfer.PDFPageOrientation = .auto
    @State private var working = false
    @State private var share: ExportFileSet?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 14) {
                            ForEach(Array(document.pages.enumerated()), id: \.element.id) { index, page in
                                VStack(spacing: 9) {
                                    if let image = store.pageImage(page, in: document, thumbnail: true) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 110, height: 150)
                                            .background(.white)
                                            .overlay(Rectangle().stroke(Color.gray.opacity(0.2)))
                                    }
                                    Label("\(index + 1)", systemImage: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(ScannerAppearance.accent)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 12)

                    Text("Compartilhar como").font(.title3.weight(.semibold))

                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("PDF pesquisavel (OCR)", isOn: $searchable).font(.subheadline)
                        HStack {
                            Text("Tamanho do PDF").font(.subheadline)
                            Spacer()
                            Picker("Tamanho do PDF", selection: $pageSize) {
                                ForEach(DocumentTransfer.PDFPageSize.allCases) { size in
                                    Text(size.rawValue).tag(size)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("export.pdfSize")
                        }
                        HStack {
                            Text("Orientacao").font(.subheadline)
                            Spacer()
                            Picker("Orientacao", selection: $orientation) {
                                ForEach(DocumentTransfer.PDFPageOrientation.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("export.pdfOrientation")
                        }
                    }
                    .padding(16)
                    .background(ScannerAppearance.surface, in: RoundedRectangle(cornerRadius: 14))

                    VStack(spacing: 0) {
                        exportRow("PDF", subtitle: "Todas as paginas (\(pageSize.rawValue), \(orientation.rawValue))", icon: "doc.richtext", color: .red) {
                            [try await DocumentTransfer.exportConfiguredPDF(document: document, root: store.root, searchable: searchable, pageSize: pageSize, orientation: orientation)]
                        }
                        Divider()
                        exportRow("JPG", subtitle: "Uma imagem por pagina, em ordem", icon: "photo", color: .orange) {
                            try await DocumentTransfer.exportImages(document: document, root: store.root)
                        }
                        Divider()
                        exportRow("TXT", subtitle: "Texto reconhecido, respeitando as tarjas", icon: "doc.text", color: ScannerAppearance.accent) {
                            [try await DocumentTransfer.exportText(document: document, root: store.root)]
                        }
                        Divider()
                        exportRow("WORD", subtitle: "Documento formatado (.doc) com texto OCR", icon: "doc.richtext.fill", color: .blue) {
                            [try await DocumentTransfer.exportWord(document: document, root: store.root)]
                        }
                        Divider()
                        exportRow("EXCEL", subtitle: "Planilha (.csv) com colunas reconstruidas", icon: "tablecells.fill", color: .green) {
                            [try await DocumentTransfer.exportExcelCSV(document: document, root: store.root)]
                        }
                    }
                    .padding(.horizontal, 16)
                    .background(ScannerAppearance.surface, in: RoundedRectangle(cornerRadius: 14))

                    Text("Escolha o formato; depois envie pelo WhatsApp, email ou salve em Arquivos.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .background(ScannerAppearance.canvas)
            .navigationTitle("\(document.pages.count) paginas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }
            }
            .disabled(working)
            .overlay { if working { ScannerProgress(message: "Preparando exportacao...") } }
            .sheet(item: $share) { ScannerActivitySheet(urls: $0.urls) }
            .alert("Nao foi possivel exportar", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("export.screen")
        }
    }

    private func exportRow(_ title: String, subtitle: String, icon: String, color: Color, work: @escaping () async throws -> [URL]) -> some View {
        Button {
            working = true
            Task { @MainActor in
                defer { working = false }
                do { share = ExportFileSet(urls: try await work()) }
                catch { failure = error.localizedDescription }
            }
        } label: {
            HStack(spacing: 15) {
                Image(systemName: icon).font(.title2).foregroundStyle(color).frame(width: 35)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("export.\(title)")
    }
}

private struct ExportFileSet: Identifiable { let id = UUID(); let urls: [URL] }

private struct ScannerSearchField: UIViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.textColor = .white
        field.attributedPlaceholder = NSAttributedString(
            string: "Pesquisar documentos e texto",
            attributes: [.foregroundColor: UIColor(white: 0.62, alpha: 1)]
        )
        field.font = UIFont.preferredFont(forTextStyle: .subheadline)
        field.adjustsFontForContentSizeCategory = true
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.returnKeyType = .search
        field.autocapitalizationType = .none
        field.accessibilityIdentifier = "library.search"
        field.isAccessibilityElement = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.text = $text
        if field.text != text { field.text = text }
    }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        @objc func changed(_ sender: UITextField) { text.wrappedValue = sender.text ?? "" }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool { textField.resignFirstResponder(); return true }
    }
}

private struct ScannerActivitySheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct ScannerProgress: View {
    let message: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 13) {
                ProgressView().tint(ScannerAppearance.accent)
                Text(message).multilineTextAlignment(.center)
                Text("Processamento local no iPhone").font(.caption).foregroundStyle(.secondary)
            }
            .padding(26)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(35)
        }
        .accessibilityIdentifier("processing.overlay")
    }
}

@MainActor
private func loadScannerPhotos(_ items: [PhotosPickerItem]) async throws -> [ScanInput] {
    var inputs: [ScanInput] = []
    for item in items {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw ScanFailure.message("Uma foto nao pode ser importada. Nenhuma pagina foi adicionada.")
        }
        inputs.append(.scannedPage(data, corners: nil, filter: .clean, autoCrop: true))
    }
    return inputs
}
