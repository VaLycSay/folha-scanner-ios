import SwiftUI
import PhotosUI
import VisionKit
import AVFoundation

private enum Palette {
    static let paper = Color(red: 0.95, green: 0.95, blue: 0.91)
    static let ink = Color(red: 0.10, green: 0.23, blue: 0.19)
    static let accent = Color(red: 0.79, green: 0.91, blue: 0.55)
}

@main
struct FolhaApp: App {
    @StateObject private var store = DocumentStore()
    var body: some Scene {
        WindowGroup {
            LibraryScreen().environmentObject(store).tint(Palette.ink)
                .overlay {
                    if store.isBusy {
                        ZStack {
                            Color.black.opacity(0.20).ignoresSafeArea()
                            VStack(spacing: 16) {
                                ProgressView()
                                Text(store.progress).font(.callout).multilineTextAlignment(.center)
                                Text("Processamento local. Nenhum upload.").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22)).padding(35)
                        }
                    }
                }
                .alert("Nao foi possivel concluir", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                    Button("OK") { store.error = nil }
                } message: { Text(store.error ?? "") }
        }
    }
}

struct LibraryScreen: View {
    @EnvironmentObject private var store: DocumentStore
    @State private var search = ""
    @State private var showingCamera = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var loadingPhotos = false

    private var filtered: [ScanDocument] {
        store.documents.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.searchableText.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SEU ARQUIVO, NO SEU IPHONE").font(.system(.caption2, design: .monospaced)).tracking(2)
                        Text("Papel vira\npossibilidade.").font(.custom("Georgia", size: 40)).foregroundStyle(Palette.ink)
                        Text("Capture, organize e encontre. Sem conta, anuncios ou assinatura.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                    HStack(spacing: 12) {
                        Button(action: openCamera) { Label("Digitalizar", systemImage: "viewfinder").frame(maxWidth: .infinity).padding(.vertical, 9) }
                            .buttonStyle(.borderedProminent).disabled(store.isBusy || loadingPhotos)
                        PhotosPicker(selection: $selectedPhotos, matching: .images) {
                            Label("Importar", systemImage: "photo.on.rectangle").padding(.vertical, 9)
                        }.buttonStyle(.bordered).disabled(store.isBusy || loadingPhotos)
                    }
                    if loadingPhotos { ProgressView("Lendo fotos selecionadas...") }
                    if !store.storageWarnings.isEmpty {
                        Label("\(store.storageWarnings.count) documento(s) precisam de recuperacao. Os arquivos foram preservados.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        Text("Documentos").font(.headline)
                        Spacer()
                        Text("\(filtered.count)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    if filtered.isEmpty {
                        ContentUnavailableView(search.isEmpty ? "Seu primeiro documento" : "Nenhum resultado", systemImage: "doc.text.viewfinder", description: Text(search.isEmpty ? "Digitalize uma folha ou importe fotos para comecar." : "Busque pelo nome ou pelo texto reconhecido."))
                    }
                    ForEach(filtered) { document in
                        NavigationLink { DocumentScreen(id: document.id) } label: {
                            HStack(spacing: 16) {
                                if let page = document.pages.first, let thumbnail = store.pageImage(page, in: document, thumbnail: true) {
                                    Image(uiImage: thumbnail).resizable().scaledToFit().frame(width: 58, height: 78).background(.white).clipShape(RoundedRectangle(cornerRadius: 5))
                                } else { Image(systemName: "doc").font(.largeTitle).frame(width: 58, height: 78) }
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(document.title).font(.headline).lineLimit(2)
                                    Text("\(document.pages.count) paginas").font(.caption).foregroundStyle(.secondary)
                                    Text(document.updatedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.padding(16).background(.white.opacity(0.80), in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain)
                    }
                    Text("PREVIA DE DESENVOLVIMENTO 0.1\nOCR pode errar: confira documentos importantes antes de enviar.")
                        .font(.caption2).foregroundStyle(.secondary).padding(.top, 16)
                }.padding(22)
            }
            .background(Palette.paper.ignoresSafeArea())
            .navigationTitle("Folha").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Nome ou texto do documento")
            .sheet(isPresented: $showingCamera) {
                CameraSheet(onFinish: { images in
                    showingCamera = false
                    store.create(inputs: images.map(ScanInput.camera))
                }, onCancel: { showingCamera = false }, onError: { failure in
                    showingCamera = false
                    store.error = failure.localizedDescription
                })
            }
            .onChange(of: selectedPhotos) { _, selected in
                guard !selected.isEmpty else { return }
                loadingPhotos = true
                Task { @MainActor in
                    defer { loadingPhotos = false }
                    do {
                        var inputs: [ScanInput] = []
                        for item in selected {
                            guard let data = try await item.loadTransferable(type: Data.self) else {
                                throw ScanFailure.message("Uma das fotos nao pode ser lida. O lote nao foi importado.")
                            }
                            inputs.append(.photo(data))
                        }
                        selectedPhotos = []
                        store.create(inputs: inputs)
                    } catch { store.error = error.localizedDescription }
                }
            }
        }
    }

    private func openCamera() {
        guard VNDocumentCameraViewController.isSupported else {
            store.error = "Digitalizacao indisponivel neste dispositivo. Use Importar."
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: showingCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { showingCamera = true } else { store.error = "A camera precisa de permissao nos Ajustes." }
                }
            }
        default: store.error = "Permita o uso da camera nos Ajustes do iPhone, ou importe fotos."
        }
    }
}

struct DocumentScreen: View {
    @EnvironmentObject private var store: DocumentStore
    let id: UUID
    @State private var renamedTitle = ""
    @State private var renaming = false
    @State private var sharedFile: SharedFile?
    @State private var previewFile: SharedFile?
    @State private var searchable = true

    var body: some View {
        Group {
            if let document = store.document(id) {
                List {
                    Section {
                        Toggle("PDF pesquisavel com OCR", isOn: $searchable)
                        Text("\(document.pages.count) paginas. Arraste para ordenar no modo Editar.").font(.caption).foregroundStyle(.secondary)
                        if document.pages.contains(where: { $0.ocrWarning != nil }) {
                            Label("Ha paginas sem OCR concluido. As imagens continuam disponiveis.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Section("Paginas") {
                        ForEach(document.pages) { page in
                            NavigationLink { PageScreen(documentID: id, pageID: page.id) } label: {
                                HStack(spacing: 14) {
                                    if let image = store.pageImage(page, in: document, thumbnail: true) {
                                        Image(uiImage: image).resizable().scaledToFit().frame(width: 54, height: 72)
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Pagina \((document.pages.firstIndex(where: { $0.id == page.id }) ?? 0) + 1)").font(.headline)
                                        Text(page.filter.title).font(.caption).foregroundStyle(.secondary)
                                        Text(page.lines.first?.text ?? "Sem texto reconhecido").font(.caption2).lineLimit(2).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 4)
                            }
                        }
                        .onMove { offsets, destination in store.movePages(document, from: offsets, to: destination) }
                        .onDelete { offsets in store.removePages(document, at: offsets) }
                    }
                    Section {
                        Button {
                            store.export(document, searchable: searchable) { previewFile = SharedFile(url: $0) }
                        } label: { Label("Visualizar PDF", systemImage: "doc.richtext") }
                        Button {
                            store.export(document, searchable: searchable) { sharedFile = SharedFile(url: $0) }
                        } label: { Label("Compartilhar PDF", systemImage: "square.and.arrow.up") }
                    }.disabled(document.pages.isEmpty || store.isBusy)
                }
                .navigationTitle(document.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { EditButton() }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { renamedTitle = document.title; renaming = true } label: { Image(systemName: "pencil") }
                    }
                }
                .alert("Nome do documento", isPresented: $renaming) {
                    TextField("Nome", text: $renamedTitle)
                    Button("Cancelar", role: .cancel) {}
                    Button("Salvar") { store.rename(document, to: renamedTitle) }
                }
            } else { ContentUnavailableView("Documento indisponivel", systemImage: "doc") }
        }
        .sheet(item: $sharedFile) { ActivitySheet(url: $0.url) }
        .sheet(item: $previewFile) { file in
            NavigationStack {
                PDFPreview(url: file.url).navigationTitle("PDF gerado").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { previewFile = nil } } }
            }
        }
    }
}

struct PageScreen: View {
    @EnvironmentObject private var store: DocumentStore
    let documentID: UUID
    let pageID: UUID
    @State private var showText = false

    var body: some View {
        RecoveredPageEditor(documentID: documentID, pageID: pageID)
    }
}
