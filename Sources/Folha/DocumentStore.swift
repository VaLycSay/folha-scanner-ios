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

    init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Folha", isDirectory: true)
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

    func create(inputs: [ScanInput]) {
        let root = self.root
        perform("Preparando paginas e reconhecendo texto...", work: {
            try ScanEngine.create(inputs: inputs, root: root)
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
