import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

private enum HomeTab: String, CaseIterable {
    case home = "Inicio", files = "Arquivos", tools = "Ferramentas", me = "Eu"
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
    case scan = "Digitalizar", pdf = "PDF", photos = "Importar fotos", files = "Importar arquivos"
    case text = "Extrair texto", signature = "Assinatura", filters = "Filtros", all = "Todas"
    var id: String { rawValue }
    var displayTitle: String {
        switch self {
        case .pdf: return "Ferramentas PDF"
        case .photos: return "Importar imagens"
        case .all: return "Tudo"
        default: return rawValue
        }
    }
    var symbol: String {
        switch self {
        case .scan: return "viewfinder"
        case .photos: return "photo.on.rectangle"
        case .files: return "folder.badge.plus"
        case .pdf: return "doc.richtext"
        case .text: return "text.viewfinder"
        case .signature: return "signature"
        case .filters: return "slider.horizontal.3"
        case .all: return "square.grid.2x2.fill"
        }
    }
    var color: Color {
        switch self {
        case .pdf: return Color(red: 0.97, green: 0.31, blue: 0.23)
        case .photos, .files: return Color(red: 0.18, green: 0.48, blue: 0.91)
        default: return ScannerAppearance.accent
        }
    }
}

struct ScannerHomeScreen: View {
    @EnvironmentObject private var store: DocumentStore
    @State private var tab: HomeTab = .home
    @State private var search = ""
    @State private var path: [UUID] = []
    @State private var camera = false
    @State private var photoPicker = false
    @State private var filePicker = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var working = false
    @State private var grid = false
    @State private var alphabetical = false
    @State private var selected: Set<UUID> = []
    @State private var selecting = false
    @State private var tool: HomeTool?
    @State private var textDestination: UUID?
    @State private var share: ExportFileSet?
    @State private var exportingDocument: ScanDocument?

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
                if tab == .me { about }
                else {
                    searchField
                    ScrollView {
                        VStack(spacing: 18) {
                            if tab == .home { toolGrid.padding(.horizontal, 16) }
                            if tab == .files { fileShortcuts.padding(.horizontal, 16) }
                            if tab == .tools { toolCatalog.padding(.horizontal, 16) }
                            if tab != .tools { documentLibrary }
                            if !store.storageWarnings.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("Documentos preservados: revisar", systemImage: "exclamationmark.triangle")
                                    ForEach(store.storageWarnings, id: \.self) { Text($0).font(.caption) }
                                }.foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(.top, 16).padding(.bottom, 24)
                    }.scrollDismissesKeyboard(.interactively).accessibilityIdentifier("library.screen")
                }
            }.background(ScannerAppearance.homeBackground)
                .navigationTitle("Documentos").navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .bottom, spacing: 0) { if path.isEmpty { bottomBar } }
                .navigationDestination(for: UUID.self) { id in ScannerDocumentScreen(id: id, startWithText: textDestination == id) }
                .fullScreenCover(isPresented: $camera) {
                    NativeCameraSheet(onFinish: { bytes in
                        camera = false
                        store.create(inputs: bytes.map(ScanInput.photo)) { path.append($0.id) }
                    }, onCancel: { camera = false }, onError: { camera = false; store.error = $0 }).ignoresSafeArea()
                }
                .photosPicker(isPresented: $photoPicker, selection: $photos, maxSelectionCount: 50, matching: .images)
                .onChange(of: photos) { _, values in
                    guard !values.isEmpty, !working else { return }
                    working = true
                    Task { @MainActor in
                        defer { working = false; photos = [] }
                        do { store.create(inputs: try await loadScannerPhotos(values)) { path.append($0.id) } }
                        catch { store.error = error.localizedDescription }
                    }
                }
                .fileImporter(isPresented: $filePicker, allowedContentTypes: [.pdf, .image]) { result in
                    guard !working else { return }
                    working = true
                    Task { @MainActor in
                        defer { working = false }
                        do { store.create(inputs: try await DocumentTransfer.importFile(result.get())) { path.append($0.id) } }
                        catch { store.error = error.localizedDescription }
                    }
                }
                .sheet(item: $tool) { chosen in toolChooser(chosen) }
                .sheet(item: $share) { ScannerActivitySheet(urls: $0.urls) }
                .sheet(item: $exportingDocument) { ScannerExportSheet(document: $0).environmentObject(store) }
                .onChange(of: search) { _, _ in selected.removeAll(); selecting = false }
                .disabled(working || store.isBusy)
                .overlay { if working { ScannerProgress(message: "Preparando arquivos...") } }
        }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            ScannerSearchField(text: $search).frame(height: 28)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .accessibilityLabel("Limpar pesquisa")
            }
        }.padding(.horizontal, 13).frame(height: 36)
            .background(ScannerAppearance.librarySurface, in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 16).padding(.top, 8)
    }

    private var toolGrid: some View {
        toolButtons(HomeTool.allCases)
    }

    private func toolButtons(_ items: [HomeTool]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 16) {
            ForEach(items) { item in
                Button { activate(item) } label: {
                    VStack(spacing: 8) {
                        Image(systemName: item.symbol).font(.system(size: 22, weight: .medium))
                            .foregroundStyle(item.color).frame(width: 45, height: 45)
                            .background(item.color.opacity(0.07), in: Circle())
                        Text(item.displayTitle).font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)
                            .multilineTextAlignment(.center).lineLimit(2).frame(height: 28, alignment: .top)
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(.plain).accessibilityIdentifier("library.tool.\(item.id)")
            }
        }
    }

    private var toolCatalog: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Ferramentas").font(.title2.weight(.semibold))
            Text("Digitalizar e importar").font(.subheadline.weight(.semibold))
            toolButtons([.scan, .files, .photos])
            Text("Editar").font(.subheadline.weight(.semibold))
            toolButtons([.signature, .filters, .text])
            Text("Exportar").font(.subheadline.weight(.semibold))
            toolButtons([.pdf])
            Text("Escolha um documento e abra a pagina para assinar ou ajustar os filtros.")
                .font(.footnote).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fileShortcuts: some View {
        HStack(spacing: 10) {
            ForEach([HomeTool.files, .photos]) { item in
                Button { activate(item) } label: {
                    VStack(spacing: 10) {
                        Image(systemName: item.symbol).font(.system(size: 25)).foregroundStyle(item.color)
                        Text(item.displayTitle).font(.caption).foregroundStyle(.primary)
                    }.frame(maxWidth: .infinity).frame(height: 88)
                        .background(ScannerAppearance.librarySurface, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).accessibilityIdentifier("files.import.\(item.id)")
            }
        }
    }

    private var documentLibrary: some View {
        VStack(spacing: 16) {
            HStack {
                Text(tab == .home ? "Recentes" : "Tudo (\(documents.count))").font(.system(size: 17, weight: .medium))
                Spacer()
                if tab == .home {
                    Button { tab = .files } label: {
                        HStack(spacing: 4) { Text("Exibir tudo"); Image(systemName: "chevron.right") }.font(.caption)
                    }.foregroundStyle(.secondary)
                } else {
                    Menu {
                        Button("Mais recentes", systemImage: "clock") { alphabetical = false }
                        Button("Nome", systemImage: "textformat.abc") { alphabetical = true }
                    } label: { Image(systemName: "arrow.up.arrow.down") }.accessibilityLabel("Ordenar documentos")
                    Button { grid.toggle() } label: { Image(systemName: grid ? "list.bullet" : "square.grid.2x2") }
                        .accessibilityLabel("Alternar lista e grade").padding(.leading, 8)
                        .accessibilityIdentifier("library.layout")
                    Button { selecting = true; selected = Set(documents.map(\.id)) } label: {
                        Image(systemName: "checkmark.square")
                    }.accessibilityLabel("Selecionar todos os documentos")
                        .accessibilityIdentifier("library.selectAll").frame(width: 44, height: 44)
                        .disabled(documents.isEmpty)
                }
            }
            if documents.isEmpty {
                VStack(spacing: 13) {
                    Image(systemName: "doc.viewfinder").font(.system(size: 43, weight: .light)).foregroundStyle(ScannerAppearance.accent)
                    Text(search.isEmpty ? "Tudo comeca com uma pagina" : "Nenhum resultado").font(.headline)
                    Text(search.isEmpty ? "Use a camera ou importe seus arquivos." : "Tente outro nome ou trecho de texto.").font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 40)
            } else if grid && tab == .files {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                    ForEach(documents) { document in
                        Button { openDocument(document) } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                ScannerThumbnail(document: document, width: 115, height: 152).frame(maxWidth: .infinity)
                                Text(document.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                Text("\(document.pages.count) paginas").font(.caption).foregroundStyle(.secondary)
                            }.foregroundStyle(.primary).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(ScannerAppearance.canvas, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).accessibilityIdentifier("library.document")
                            .overlay(alignment: .topTrailing) { selectionButton(document).padding(4) }
                    }
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(documents) { document in
                        HStack(spacing: 12) {
                            Button { openDocument(document) } label: {
                                HStack(spacing: 13) {
                                    ScannerThumbnail(document: document)
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(document.title).font(.system(size: 15, weight: .medium)).lineLimit(2)
                                        HStack(spacing: 9) {
                                            Text(document.updatedAt.formatted(date: .numeric, time: .shortened))
                                            Label("\(document.pages.count)", systemImage: "doc")
                                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.foregroundStyle(.primary).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("library.document")
                            selectionButton(document)
                        }.padding(.vertical, 12)
                        if tab == .home && documents.first?.id == document.id && !selecting {
                            HStack(spacing: 8) {
                                recentAction("Compartilhar", identifier: "library.recent.share") { exportingDocument = document }
                                recentAction("Visualizar", identifier: "library.recent.open") { openDocument(document) }
                            }.padding(.bottom, 12)
                        }
                        Divider().padding(.leading, 69)
                    }
                }
            }
        }.padding(.horizontal, 16).padding(.vertical, 14)
            .background(ScannerAppearance.librarySurface)
    }

    private func recentAction(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).foregroundStyle(.primary)
                .frame(maxWidth: .infinity).frame(minHeight: 36)
                .background(ScannerAppearance.actionSurface, in: RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain).accessibilityIdentifier(identifier)
    }

    private func selectionButton(_ document: ScanDocument) -> some View {
        Button { toggleSelection(document.id) } label: {
            Image(systemName: selected.contains(document.id) ? "checkmark.square.fill" : "square")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(selected.contains(document.id) ? ScannerAppearance.accent : Color(.tertiaryLabel))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Selecionar \(document.title)")
            .accessibilityValue(selected.contains(document.id) ? "Selecionado" : "Nao selecionado")
            .accessibilityIdentifier("library.select")
    }

    private func toggleSelection(_ id: UUID) {
        selecting = true
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func openDocument(_ document: ScanDocument) {
        if selecting { toggleSelection(document.id) }
        else { textDestination = nil; path.append(document.id) }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if selecting {
                HStack {
                    Button("Cancelar") { selected.removeAll(); selecting = false }
                        .accessibilityIdentifier("library.selection.cancel")
                    Spacer()
                    Text("\(selected.count) selecionados").font(.caption)
                        .accessibilityIdentifier("library.selection.count")
                    Spacer()
                    Button { shareSelected() } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Compartilhar PDFs selecionados")
                        .disabled(selected.isEmpty).accessibilityIdentifier("library.selection.share")
                }.padding(.horizontal, 22).frame(height: 62)
            } else {
                HStack(spacing: 0) {
                    tabButton(.home)
                    tabButton(.files)
                    Button { camera = true } label: {
                        Image(systemName: "camera.fill").font(.system(size: 24)).foregroundStyle(.white)
                            .frame(width: 55, height: 55).background(ScannerAppearance.accent, in: Circle())
                    }.accessibilityLabel("Digitalizar").accessibilityIdentifier("library.scan")
                        .offset(y: -10).frame(maxWidth: .infinity)
                    tabButton(.tools)
                    tabButton(.me)
                }.padding(.horizontal, 5).padding(.top, 3)
            }
        }.background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            .padding(.horizontal, 16).padding(.bottom, 6)
    }

    private func tabButton(_ item: HomeTab) -> some View {
        Button { tab = item; selected.removeAll(); selecting = false } label: {
            VStack(spacing: 5) {
                Image(systemName: item.symbol).font(.system(size: 18))
                Text(item == .files ? "Documentos" : item.rawValue).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
            }
                .foregroundStyle(tab == item ? ScannerAppearance.accent : ScannerAppearance.mutedInk)
                .frame(maxWidth: .infinity).frame(height: 55)
                .background(tab == item ? ScannerAppearance.librarySurface : .clear, in: Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("library.tab.\(item.rawValue)")
    }

    private var about: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Image(systemName: "doc.viewfinder").font(.largeTitle).foregroundStyle(ScannerAppearance.accent)
                    VStack(alignment: .leading) { Text("Scanner REA").font(.title2.bold()); Text("0.4.0 - armazenamento local").font(.caption).foregroundStyle(.secondary) }
                }
                Label("\(store.documents.count) documentos neste iPhone", systemImage: "iphone")
                Text("Sem conta, anuncios ou assinatura. Camera, edicao e reconhecimento de texto sao processados no aparelho.")
                Text("Reconstrucao independente orientada pelo REA e referencias oficiais. Nao e o aplicativo original nem uma equivalencia completa comprovada.").font(.footnote).foregroundStyle(.secondary)
                Text("Exportacoes respeitam tarjas. Os originais continuam guardados para reedicao; nao compartilhe a pasta interna do aplicativo.").font(.footnote).foregroundStyle(.secondary)
                Text("Nuvem, IA proprietaria, Word/Excel e assinatura digital certificada nao fazem parte desta versao.").font(.footnote).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toolChooser(_ chosen: HomeTool) -> some View {
        NavigationStack {
            List {
                Section {
                    ForEach(documents) { document in
                        Button {
                            textDestination = chosen == .text ? document.id : nil
                            tool = nil
                            path.append(document.id)
                        } label: { HStack(spacing: 14) { ScannerThumbnail(document: document); Text(document.title).foregroundStyle(.primary) } }
                    }
                } header: { Text("Escolha um documento") }
                footer: { Text("Para assinatura e filtros, abra a pagina desejada. PDF e texto ficam na tela do documento.") }
                if documents.isEmpty { Text("Digitalize ou importe um documento primeiro.").foregroundStyle(.secondary) }
            }.navigationTitle(chosen.rawValue).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { tool = nil } } }
        }
    }

    private func activate(_ item: HomeTool) {
        switch item {
        case .scan: camera = true
        case .photos: photoPicker = true
        case .files: filePicker = true
        case .all: tab = .tools
        default: tool = item
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
}

private struct ScannerThumbnail: View {
    @EnvironmentObject private var store: DocumentStore
    let document: ScanDocument
    var width: CGFloat = 56
    var height: CGFloat = 72
    var body: some View {
        Group {
            if let page = document.pages.first, let image = store.pageImage(page, in: document, thumbnail: true) { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "doc.text").foregroundStyle(.secondary) }
        }.frame(width: width, height: height).background(ScannerAppearance.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 4)).overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.18)))
    }
}

private struct ScannerDocumentScreen: View {
    @EnvironmentObject private var store: DocumentStore
    let id: UUID
    var startWithText = false
    @State private var editingPageID: UUID?
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

    var body: some View {
        Group {
            if let document = store.document(id) {
                List {
                    Section {
                        Picker("Conteudo", selection: $textMode) { Text("Imagem").tag(false); Text("Texto").tag(true) }
                            .pickerStyle(.segmented).padding(.vertical, 3)
                    }.listRowBackground(ScannerAppearance.surface).listRowSeparator(.hidden)
                    if textMode {
                        Section {
                            let text = DocumentTransfer.visibleText(document: document)
                            Text(text.isEmpty ? "Nenhum texto reconhecido." : text).textSelection(.enabled)
                                .font(.body).padding(.vertical, 16).accessibilityIdentifier("document.text")
                        }.listRowBackground(ScannerAppearance.surface)
                    } else if reordering {
                        Section("Arraste para ordenar; deslize para remover") {
                            ForEach(Array(document.pages.enumerated()), id: \.element.id) { index, page in
                                HStack { pageImage(page, document: document).frame(width: 45, height: 60); Text("Pagina \(index + 1)") }
                            }.onMove { store.movePages(document, from: $0, to: $1) }.onDelete { store.removePages(document, at: $0) }
                        }.environment(\.editMode, .constant(.active))
                    } else {
                        Section {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 18) {
                                ForEach(Array(document.pages.enumerated()), id: \.element.id) { index, page in
                                    Button {
                                        guard editingPageID == nil else { return }
                                        editingPageID = page.id
                                    } label: {
                                        VStack(spacing: 8) {
                                            pageImage(page, document: document).frame(height: 200).frame(maxWidth: .infinity)
                                                .background(ScannerAppearance.surface).overlay(Rectangle().stroke(Color.gray.opacity(0.14)))
                                            HStack { Text("\(index + 1)").font(.caption.weight(.medium)); Spacer(); Text(page.filter.title).font(.caption2).foregroundStyle(.secondary) }
                                        }.foregroundStyle(.primary)
                                    }.buttonStyle(.plain).accessibilityIdentifier("document.page")
                                        .contextMenu { Button("Refazer captura", systemImage: "camera.rotate") { replacement = page.id; camera = true } }
                                }
                            }.padding(.vertical, 10)
                        }.listRowBackground(ScannerAppearance.canvas).listRowSeparator(.hidden)
                    }
                    Section {
                        Text("\(document.pages.count) paginas").font(.caption).foregroundStyle(.secondary)
                        ForEach(document.pages.filter { $0.ocrWarning != nil }) { Text($0.ocrWarning ?? "").font(.caption).foregroundStyle(.orange) }
                    }.listRowBackground(ScannerAppearance.canvas).listRowSeparator(.hidden)
                }.listStyle(.plain).scrollContentBackground(.hidden).background(ScannerAppearance.canvas)
                    .accessibilityIdentifier("document.screen")
                    .navigationDestination(item: $editingPageID) { pageID in
                        RecoveredPageEditor(documentID: id, pageID: pageID)
                    }
                    .navigationTitle(document.title).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { title = document.title; rename = true } label: { Image(systemName: "pencil") }
                                .accessibilityLabel("Renomear").accessibilityIdentifier("document.rename")
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if editingPageID == nil {
                        HStack {
                            footerButton("Adicionar", icon: "plus") { add = true }
                            footerButton(reordering ? "Concluir" : "Ordenar", icon: reordering ? "checkmark" : "square.grid.2x2") { reordering.toggle(); textMode = false }
                            footerButton("PDF", icon: "doc.richtext") { store.export(document, searchable: true) { preview = SharedFile(url: $0) } }
                                .accessibilityIdentifier("document.previewPDF").disabled(document.pages.isEmpty)
                            footerButton("Compartilhar", icon: "square.and.arrow.up") { export = true }
                                .accessibilityIdentifier("document.share").disabled(document.pages.isEmpty)
                        }.padding(.vertical, 10).background(ScannerAppearance.surface).overlay(alignment: .top) { Divider() }
                        }
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
                        NativeCameraSheet(singleOnly: replacement != nil, onFinish: { bytes in
                            camera = false
                            if let pageID = replacement, let data = bytes.first { store.replace(input: .photo(data), in: document, pageID: pageID) }
                            else { store.append(inputs: bytes.map(ScanInput.photo), to: document) }
                            replacement = nil
                        }, onCancel: { camera = false; replacement = nil }, onError: { camera = false; replacement = nil; store.error = $0 }).ignoresSafeArea()
                    }
                    .sheet(item: $preview) { file in
                        NavigationStack {
                            PDFPreview(url: file.url).accessibilityIdentifier("pdf.preview")
                                .navigationTitle("PDF - \(document.pages.count) paginas").navigationBarTitleDisplayMode(.inline)
                                .toolbar { Button("Fechar") { preview = nil } }
                        }
                    }
                    .sheet(isPresented: $export) { ScannerExportSheet(document: document).environmentObject(store) }
                    .overlay { if importing { ScannerProgress(message: "Importando paginas...") } }
                    .onAppear { if startWithText { textMode = true } }
            } else { ContentUnavailableView("Documento indisponivel", systemImage: "doc.questionmark") }
        }
    }
    private func pageImage(_ page: ScanPage, document: ScanDocument) -> some View {
        Group {
            if let image = store.pageImage(page, in: document, thumbnail: true) { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "doc.questionmark").foregroundStyle(.secondary) }
        }
    }
    private func footerButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) { Image(systemName: icon).font(.system(size: 21)); Text(title).font(.system(size: 10)) }
                .foregroundStyle(.primary).frame(maxWidth: .infinity).frame(height: 44)
        }.buttonStyle(.plain)
    }
}

private struct ScannerExportSheet: View {
    @EnvironmentObject private var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    let document: ScanDocument
    @State private var searchable = true
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
                                        Image(uiImage: image).resizable().scaledToFit().frame(width: 110, height: 150)
                                            .background(.white).overlay(Rectangle().stroke(Color.gray.opacity(0.2)))
                                    }
                                    Label("\(index + 1)", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(ScannerAppearance.accent)
                                }
                            }
                        }
                    }.padding(.vertical, 12)
                    Text("Compartilhar como").font(.title3.weight(.semibold))
                    Toggle("PDF pesquisavel (OCR)", isOn: $searchable).font(.subheadline)
                    VStack(spacing: 0) {
                        exportRow("PDF", subtitle: "Todas as paginas em um documento", icon: "doc.richtext", color: .red) { try await DocumentTransfer.exportPDFs(documents: [document], root: store.root, searchable: searchable) }
                        Divider()
                        exportRow("JPG", subtitle: "Uma imagem por pagina, em ordem", icon: "photo", color: .orange) { try await DocumentTransfer.exportImages(document: document, root: store.root) }
                        Divider()
                        exportRow("TXT", subtitle: "Texto reconhecido, respeitando as tarjas", icon: "doc.text", color: ScannerAppearance.accent) { [try await DocumentTransfer.exportText(document: document, root: store.root)] }
                    }.padding(.horizontal, 16).background(ScannerAppearance.surface, in: RoundedRectangle(cornerRadius: 14))
                    Text("Escolha o formato; depois envie pelo WhatsApp, email ou salve em Arquivos.").font(.footnote).foregroundStyle(.secondary)
                }.padding(20)
            }.background(ScannerAppearance.canvas)
                .navigationTitle("\(document.pages.count) paginas").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } } }
                .disabled(working).overlay { if working { ScannerProgress(message: "Preparando exportacao...") } }
                .sheet(item: $share) { ScannerActivitySheet(urls: $0.urls) }
                .alert("Nao foi possivel exportar", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                    Button("OK", role: .cancel) { failure = nil }
                } message: { Text(failure ?? "") }
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
            }.padding(.vertical, 18).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("export.\(title)")
    }
}

private struct ExportFileSet: Identifiable { let id = UUID(); let urls: [URL] }
private struct ScannerSearchField: UIViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = "Pesquisar documentos e texto"
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
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
private struct ScannerProgress: View {
    let message: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()
            VStack(spacing: 13) { ProgressView(); Text(message).multilineTextAlignment(.center); Text("Processamento local no iPhone").font(.caption).foregroundStyle(.secondary) }
                .padding(26).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding(35)
        }.accessibilityIdentifier("processing.overlay")
    }
}
@MainActor
private func loadScannerPhotos(_ items: [PhotosPickerItem]) async throws -> [ScanInput] {
    var inputs: [ScanInput] = []
    for item in items {
        guard let data = try await item.loadTransferable(type: Data.self) else { throw ScanFailure.message("Uma foto nao pode ser importada. Nenhuma pagina foi adicionada.") }
        inputs.append(.photo(data))
    }
    return inputs
}
