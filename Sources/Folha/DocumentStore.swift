import Foundation
import SwiftUI
import UIKit

@MainActor
final class DocumentStore: ObservableObject {
    @Published private(set) var documents: [ScanDocument] = []
    @Published private(set) var isBusy = false
    @Published private(set) var progress = ""
    @Published var error: String?
    @Published private(set) var storageWarnings: [String] = []
    let root: URL
    private let worker = DispatchQueue(label: "com.valyc.folha.processing", qos: .userInitiated)

    init(root suppliedRoot: URL? = nil) {
        let testing = ProcessInfo.processInfo.arguments.contains("--uitesting")
        root = suppliedRoot ?? (testing
            ? FileManager.default.temporaryDirectory.appendingPathComponent("rea-ui-tests/\(UUID().uuidString)", isDirectory: true)
            : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Folha", isDirectory: true))
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            reload()
        } catch { self.error = error.localizedDescription }
    }

    func reload() {
        do {
            let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            var loaded: [ScanDocument] = []
            var warnings: [String] = []
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
                do {
                    let document = try decoder.decode(ScanDocument.self, from: Data(contentsOf: folder.appendingPathComponent("document.json")))
                    guard document.id.uuidString == folder.lastPathComponent else {
                        throw ScanFailure.message("Identidade da pasta nao corresponde ao documento.")
                    }
                    loaded.append(document)
                } catch { warnings.append("Documento preservado, mas nao aberto: \(folder.lastPathComponent). \(error.localizedDescription)") }
            }
            documents = loaded.sorted { $0.updatedAt > $1.updatedAt }
            storageWarnings = warnings
        } catch { self.error = error.localizedDescription }
    }

    func document(_ id: UUID) -> ScanDocument? { documents.first { $0.id == id } }

    func pageImage(_ page: ScanPage, in document: ScanDocument, thumbnail: Bool = false) -> UIImage? {
        let filename = thumbnail ? page.thumbnailFile : page.renderedFile
        return UIImage(contentsOfFile: root.appendingPathComponent(document.id.uuidString).appendingPathComponent(filename).path)
    }

    private func perform<T>(_ label: String, work: @escaping () throws -> T, completion: @escaping (T) -> Void) {
        guard !isBusy else { return }
        isBusy = true
        progress = label
        error = nil
        worker.async {
            let result = Result { try work() }
            DispatchQueue.main.async {
                self.isBusy = false
                self.progress = ""
                switch result {
                case .success(let value): self.reload(); completion(value)
                case .failure(let failure): self.error = failure.localizedDescription
                }
            }
        }
    }

    func create(inputs: [ScanInput], completion: @escaping (ScanDocument) -> Void = { _ in }) {
        let root = self.root
        perform("Preparando paginas e reconhecendo texto...", work: {
            try ScanEngine.create(inputs: inputs, root: root)
        }, completion: completion)
    }

    func append(inputs: [ScanInput], to document: ScanDocument) {
        let root = self.root
        perform("Adicionando paginas...", work: {
            try ScanEngine.append(inputs: inputs, to: document, root: root)
        }, completion: { _ in })
    }

    func replace(input: ScanInput, in document: ScanDocument, pageID: UUID) {
        let root = self.root
        perform("Substituindo a captura...", work: {
            try ScanEngine.replace(input: input, in: document, pageID: pageID, root: root)
        }, completion: { _ in })
    }

    func seedUITestDocumentIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--uitesting"),
              ProcessInfo.processInfo.arguments.contains("--seed-test-document"), documents.isEmpty, !isBusy else { return }
        let root = self.root
        perform("Preparando documento de teste...", work: {
            let inputs: [ScanInput] = (1...2).map { number in
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1100), format: format).image { context in
                    UIColor.white.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 800, height: 1100))
                    let text = "DOCUMENTO SINTETICO REA\n\nPagina \(number) de 2\n\nTeste local de leitura e exportacao.\nSem dados pessoais ou documentos reais."
                    (text as NSString).draw(in: CGRect(x: 60, y: 90, width: 680, height: 800), withAttributes: [
                        .font: UIFont.systemFont(ofSize: 30), .foregroundColor: UIColor.black
                    ])
                }
                return .camera(image)
            }
            var document = try ScanEngine.create(inputs: inputs, root: root)
            document.title = "Documento de teste REA"
            try ScanEngine.writeManifest(document, folder: root.appendingPathComponent(document.id.uuidString))
            return document
        }, completion: { _ in })
    }

    func revise(document: ScanDocument, page: ScanPage) {
        let root = self.root
        perform("Atualizando imagem e texto...", work: {
            try ScanEngine.revise(document: document, page: page, root: root)
        }, completion: { _ in })
    }

    func export(_ document: ScanDocument, searchable: Bool, completion: @escaping (URL) -> Void) {
        let root = self.root
        perform("Gerando PDF com todas as paginas...", work: {
            try ScanEngine.exportPDF(document: document, root: root, searchable: searchable)
        }, completion: completion)
    }

    func rename(_ document: ScanDocument, to title: String) {
        guard !isBusy else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var edited = document
        edited.title = String(title.prefix(120))
        persist(edited)
    }

    func movePages(_ document: ScanDocument, from offsets: IndexSet, to destination: Int) {
        guard !isBusy else { return }
        var edited = document
        edited.pages.move(fromOffsets: offsets, toOffset: destination)
        persist(edited)
    }

    func removePages(_ document: ScanDocument, at offsets: IndexSet) {
        guard !isBusy else { return }
        var edited = document
        edited.pages.remove(atOffsets: offsets)
        // Retain source files; removing a page from this document is non-destructive.
        persist(edited)
    }

    private func persist(_ document: ScanDocument) {
        do {
            var edited = document
            edited.updatedAt = Date()
            try ScanEngine.writeManifest(edited, folder: root.appendingPathComponent(edited.id.uuidString))
            reload()
        } catch { self.error = error.localizedDescription }
    }
}
