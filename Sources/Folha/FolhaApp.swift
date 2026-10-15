import SwiftUI
import PhotosUI
import UIKit

@main
struct FolhaApp: App {
    @StateObject private var store = DocumentStore()
    var body: some Scene {
        WindowGroup {
            ScannerHomeScreen().environmentObject(store)
                .tint(ScannerAppearance.accent)
                .overlay {
                    if store.isBusy {
                        ZStack {
                            Color.black.opacity(0.22).ignoresSafeArea()
                            VStack(spacing: 14) {
                                ProgressView()
                                Text(store.progress).multilineTextAlignment(.center)
                                Text("Processamento local no iPhone").font(.caption).foregroundStyle(.secondary)
                            }.padding(26).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding(35)
                        }.accessibilityIdentifier("processing.overlay")
                    }
                }
                .alert("Nao foi possivel concluir", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                    Button("OK", role: .cancel) { store.error = nil }
                } message: { Text(store.error ?? "") }
                .task { store.seedUITestDocumentIfRequested() }
        }
    }
}

private struct LibraryScreen: View {
    @EnvironmentObject private var store: DocumentStore
    @State private var search = ""
    @State private var path: [UUID] = []
    @State private var camera = false
    @State private var importing = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var information = false
    private var documents: [ScanDocument] {
        search.isEmpty ? store.documents : store.documents.filter {
            $0.title.localizedCaseInsensitiveContains(search) || $0.searchableText.localizedCaseInsensitiveContains(search)
        }
    }
    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !store.storageWarnings.isEmpty {
                    Section {
                        Label("Documentos preservados que precisam de atencao", systemImage: "exclamationmark.triangle")
                        ForEach(store.storageWarnings, id: \.self) { Text($0).font(.caption) }
                    }
                }
                if documents.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "Seus documentos" : "Nenhum resultado", systemImage: "doc.viewfinder", description: Text("Digitalize uma pagina ou importe fotos para comecar."))
                        .listRowBackground(Color.clear)
                } else {
                    Section("\(documents.count) documentos") {
                        ForEach(documents) { document in
                            NavigationLink(value: document.id) {
                                HStack(spacing: 14) {
                                    DocumentThumbnail(document: document)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(document.title).font(.headline).lineLimit(2)
                                        Text("\(document.pages.count) paginas  |  \(document.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 4)
                            }.accessibilityIdentifier("library.document")
                        }
                    }
                }
            }
            .listStyle(.plain).accessibilityIdentifier("library.screen")
            .navigationTitle("Documentos")
            .searchable(text: $search, prompt: "Nome ou texto do documento")
            .navigationDestination(for: UUID.self) { DocumentScreen(id: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { information = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("Sobre esta reconstrucao")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $photos, maxSelectionCount: 50, matching: .images) {
                        Image(systemName: "photo.on.rectangle.angled")
                    }.accessibilityLabel("Importar fotos").disabled(store.isBusy || importing)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { camera = true } label: {
                    Label("Digitalizar", systemImage: "camera.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                }.buttonStyle(.borderedProminent).padding().background(.bar)
                    .disabled(store.isBusy || importing).accessibilityIdentifier("library.scan")
            }
            .fullScreenCover(isPresented: $camera) {
                NativeCameraSheet(onFinish: { bytes in
                    camera = false
                    store.create(inputs: bytes.map(ScanInput.photo)) { path.append($0.id) }
                }, onCancel: { camera = false }, onError: { camera = false; store.error = $0 }).ignoresSafeArea()
            }
            .onChange(of: photos) { _, selected in
                guard !selected.isEmpty, !importing else { return }
                importing = true
                Task { @MainActor in
                    defer { importing = false; photos = [] }
                    do { store.create(inputs: try await loadPhotos(selected)) { path.append($0.id) } }
                    catch { store.error = error.localizedDescription }
                }
            }
            .sheet(isPresented: $information) {
                NavigationStack {
                    List {
                        Section("Scanner REA 0.3") {
                            Text("Reconstrucao independente orientada por evidencias estaticas da versao historica 5.26.12.")
                            Text("Editor: recorte, rotacao, filtros, ajustes, texto, assinatura, anotacoes, tarjas e OCR. Documentos: varias paginas, reordenacao e PDF pesquisavel.")
                        }
                        Section("Limites desta versao") {
                            Text("Os filtros de imagem e a camera sao implementacoes proprias. A aparencia e o comportamento completo do aplicativo de referencia ainda nao foram comprovados em execucao.")
                            Text("Nao inclui conta, nuvem, OCR de planilhas, documentos de identidade especializados ou assinatura digital certificada.")
                            Text("As tarjas protegem o PDF exportado. As imagens originais permanecem localmente para reedicao.")
                        }
                    }.navigationTitle("Sobre").toolbar { Button("Fechar") { information = false } }
                }
            }
        }
    }
}

private struct DocumentThumbnail: View {
    @EnvironmentObject private var store: DocumentStore
    let document: ScanDocument
    var body: some View {
        Group {
            if let page = document.pages.first, let image = store.pageImage(page, in: document, thumbnail: true) {
                Image(uiImage: image).resizable().scaledToFit()
            } else { Image(systemName: "doc.text").foregroundStyle(.secondary) }
        }.frame(width: 56, height: 76).background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.gray.opacity(0.25)))
    }
}

private struct DocumentScreen: View {
    @EnvironmentObject private var store: DocumentStore
    let id: UUID
    @State private var searchable = true
    @State private var rename = false
    @State private var title = ""
    @State private var camera = false
    @State private var replacement: UUID?
    @State private var photos: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var preview: SharedFile?
    @State private var sharing: SharedFile?
    var body: some View {
        Group {
            if let document = store.document(id) {
                List {
                    Section {
                        ForEach(Array(document.pages.enumerated()), id: \.element.id) { index, page in
                            NavigationLink {
                                RecoveredPageEditor(documentID: id, pageID: page.id)
                            } label: {
                                HStack(spacing: 14) {
                                    if let image = store.pageImage(page, in: document, thumbnail: true) {
                                        Image(uiImage: image).resizable().scaledToFit().frame(width: 64, height: 90)
                                    }
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("Pagina \(index + 1)").font(.headline)
                                        Text(page.filter.title).font(.caption).foregroundStyle(.secondary)
                                        Text(page.lines.first?.text ?? "Sem texto reconhecido").lineLimit(2).font(.caption)
                                        if let warning = page.ocrWarning { Text(warning).font(.caption2).foregroundStyle(.orange) }
                                    }
                                }.padding(.vertical, 4)
                            }.accessibilityIdentifier("document.page")
                                .contextMenu { Button("Refazer captura", systemImage: "camera.rotate") { replacement = page.id; camera = true } }
                        }
                        .onMove { store.movePages(document, from: $0, to: $1) }
                        .onDelete { store.removePages(document, at: $0) }
                    } header: { Text("\(document.pages.count) paginas") }
                    footer: { Text("Editar permite ordenar ou retirar paginas. Toque em uma pagina para ajustar imagem e texto.") }
                    Section {
                        Button { replacement = nil; camera = true } label: { Label("Continuar captura", systemImage: "camera.badge.ellipsis") }
                        PhotosPicker(selection: $photos, maxSelectionCount: 50, matching: .images) { Label("Adicionar fotos", systemImage: "photo.badge.plus") }
                    }
                    Section("Exportar") {
                        Toggle("PDF pesquisavel (OCR)", isOn: $searchable)
                        Button { store.export(document, searchable: searchable) { preview = SharedFile(url: $0) } } label: {
                            Label("Visualizar PDF", systemImage: "doc.richtext")
                        }.accessibilityIdentifier("document.previewPDF").disabled(document.pages.isEmpty)
                        Button { store.export(document, searchable: searchable) { sharing = SharedFile(url: $0) } } label: {
                            Label("Compartilhar PDF", systemImage: "square.and.arrow.up")
                        }.disabled(document.pages.isEmpty)
                    }
                }.accessibilityIdentifier("document.screen")
                    .navigationTitle(document.title).navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) { EditButton() }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { title = document.title; rename = true } label: { Image(systemName: "pencil") }
                                .accessibilityLabel("Renomear").accessibilityIdentifier("document.rename")
                        }
                    }
                    .alert("Renomear documento", isPresented: $rename) {
                        TextField("Nome", text: $title).accessibilityIdentifier("document.renameField")
                        Button("Cancelar", role: .cancel) { }
                        Button("Salvar") { store.rename(document, to: title) }
                    }
                    .disabled(store.isBusy || importing)
                    .onChange(of: photos) { _, selected in
                        guard !selected.isEmpty, !importing else { return }
                        importing = true
                        Task { @MainActor in
                            defer { importing = false; photos = [] }
                            do { store.append(inputs: try await loadPhotos(selected), to: document) }
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
                    .sheet(item: $sharing) { ActivitySheet(url: $0.url) }
            } else { ContentUnavailableView("Documento indisponivel", systemImage: "doc.questionmark") }
        }
    }
}

@MainActor
private func loadPhotos(_ items: [PhotosPickerItem]) async throws -> [ScanInput] {
    var inputs: [ScanInput] = []
    for item in items {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw ScanFailure.message("Uma foto nao pode ser importada. Nenhuma pagina foi adicionada.")
        }
        inputs.append(.photo(data))
    }
    return inputs
}
