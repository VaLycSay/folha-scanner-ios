import SwiftUI
import UIKit

enum EditorSheet: String, Identifiable {
    case text, annotation, signature, redaction, ocr
    var id: String { rawValue }
    var title: String {
        switch self {
        case .text: return "Adicionar texto"
        case .annotation: return "Anotar"
        case .signature: return "Desenhar assinatura"
        case .redaction: return "Ocultar area"
        case .ocr: return "Texto reconhecido"
        }
    }
}

// Pending overlays never touch the store. Commit returns page-normalized TOP-LEFT data.
struct EditorOverlayComposer: View {
    @Environment(\.dismiss) private var dismiss
    let mode: EditorSheet
    let image: UIImage
    let onCommit: ([PageOverlay]) -> Void
    @State private var text = ""
    @State private var x = 0.1
    @State private var y = 0.1
    @State private var width = 0.7
    @State private var height = 0.12
    @State private var lineWidth = 0.006
    @State private var strokes: [[UnitPointRecord]] = []
    @State private var activeStroke: [UnitPointRecord] = []
    @State private var rectangles: [CGRect] = []
    @State private var activeRectangle: CGRect?
    private var canCommit: Bool {
        if mode == .text { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if mode == .redaction { return !rectangles.isEmpty }
        return !strokes.isEmpty
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text(instructions).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                GeometryReader { geometry in
                    let size = EditorGeometry.fittedSize(image.size, inside: geometry.size)
                    canvas(size: size).frame(width: size.width, height: size.height)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }.padding(.horizontal, 12)
                if mode == .text { textControls }
                else {
                    HStack {
                        Button("Desfazer", systemImage: "arrow.uturn.backward") { undo() }
                            .disabled(mode == .redaction ? rectangles.isEmpty : strokes.isEmpty)
                            .accessibilityIdentifier("editor.overlay.undo")
                        if mode != .redaction {
                            Slider(value: $lineWidth, in: 0.002...0.025)
                                .accessibilityLabel("Espessura do traco")
                                .accessibilityIdentifier("editor.overlay.line-width")
                        }
                    }.padding()
                }
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle(mode.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }.accessibilityIdentifier("editor.overlay.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Aplicar") { onCommit(makeOverlays()); dismiss() }
                        .disabled(!canCommit).accessibilityIdentifier("editor.overlay.commit")
                }
            }.tint(.green)
        }
    }
    private var instructions: String {
        switch mode {
        case .text: return "Posicione a caixa e ajuste o tamanho. A previa e aproximada; a pagina usa o motor de renderizacao."
        case .redaction: return "Arraste retangulos sobre o que deseja ocultar. A cobertura e preta e opaca."
        case .signature: return "Desenhe sua assinatura na posicao desejada. Nenhuma assinatura pronta e importada."
        default: return "Desenhe sobre a pagina. Os tracos so serao gravados ao salvar a pagina."
        }
    }
    private func canvas(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
            ForEach(Array(strokes.enumerated()), id: \.offset) { _, points in
                stroke(points, size: size).stroke(Color.black,
                    style: StrokeStyle(lineWidth: CGFloat(lineWidth) * size.width, lineCap: .round, lineJoin: .round))
            }
            stroke(activeStroke, size: size).stroke(Color.black,
                style: StrokeStyle(lineWidth: CGFloat(lineWidth) * size.width, lineCap: .round, lineJoin: .round))
            ForEach(Array(rectangles.enumerated()), id: \.offset) { _, rect in redaction(rect, size: size) }
            if let rect = activeRectangle { redaction(rect, size: size) }
            if mode == .text {
                Text(text.isEmpty ? "Seu texto" : text)
                    .font(.system(size: max(8, CGFloat(height) * size.height * 0.65)))
                    .foregroundStyle(.black)
                    .frame(width: CGFloat(width) * size.width, height: CGFloat(height) * size.height, alignment: .topLeading)
                    .clipped()
                    .overlay(Rectangle().stroke(Color.green, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .offset(x: CGFloat(x) * size.width, y: CGFloat(y) * size.height)
            }
        }
        .frame(width: size.width, height: size.height).clipped().contentShape(Rectangle())
        .accessibilityIdentifier("editor.overlay.canvas")
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard size.width > 0, size.height > 0 else { return }
                let point = normalized(gesture.location, size: size)
                if mode == .text {
                    x = min(1 - width, Double(point.x)); y = min(1 - height, Double(point.y))
                } else if mode == .redaction {
                    activeRectangle = EditorGeometry.rectangle(from: normalized(gesture.startLocation, size: size), to: point)
                } else {
                    if activeStroke.isEmpty { activeStroke.append(.init(normalized(gesture.startLocation, size: size))) }
                    if activeStroke.count < 8192 { activeStroke.append(.init(point)) }
                }
            }
            .onEnded { _ in
                if mode == .redaction {
                    if let rect = activeRectangle, rect.width > 0.002, rect.height > 0.002 { rectangles.append(rect) }
                    activeRectangle = nil
                } else if mode != .text {
                    if activeStroke.count > 1 { strokes.append(activeStroke) }
                    activeStroke = []
                }
            })
    }
    private var textControls: some View {
        VStack(spacing: 8) {
            TextField("Texto da pagina", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3)
                .accessibilityIdentifier("editor.text.content")
                .onChange(of: text) { value in if value.count > 2000 { text = String(value.prefix(2000)) } }
            control("Horizontal", value: $x, range: 0...max(0, 1 - width), id: "x")
            control("Vertical", value: $y, range: 0...max(0, 1 - height), id: "y")
            control("Largura", value: $width, range: 0.1...0.95, id: "width")
            control("Tamanho", value: $height, range: 0.025...0.35, id: "height")
        }.padding(.horizontal).padding(.bottom, 12)
        .onChange(of: width) { value in x = min(x, 1 - value) }
        .onChange(of: height) { value in y = min(y, 1 - value) }
    }
    private func control(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, id: String) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 70, alignment: .leading)
            Slider(value: value, in: range).accessibilityLabel(title).accessibilityIdentifier("editor.text.\(id)")
        }
    }
    private func normalized(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x / size.width)), y: min(1, max(0, point.y / size.height)))
    }
    private func stroke(_ points: [UnitPointRecord], size: CGSize) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
            for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height)) }
        }
    }
    private func redaction(_ rect: CGRect, size: CGSize) -> some View {
        Rectangle().fill(Color.black).frame(width: rect.width * size.width, height: rect.height * size.height)
            .offset(x: rect.minX * size.width, y: rect.minY * size.height)
    }
    private func undo() {
        if mode == .redaction { if !rectangles.isEmpty { rectangles.removeLast() } }
        else if !strokes.isEmpty { strokes.removeLast() }
    }
    private func makeOverlays() -> [PageOverlay] {
        if mode == .text {
            return [PageOverlay(id: UUID(), kind: .text, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                points: [], x: x, y: y, width: width, height: height, lineWidth: lineWidth)]
        }
        if mode == .redaction {
            return rectangles.map { rect in
                PageOverlay(id: UUID(), kind: .redaction, text: nil, points: [], x: Double(rect.minX), y: Double(rect.minY),
                    width: Double(rect.width), height: Double(rect.height), lineWidth: 0)
            }
        }
        return strokes.map { points in
            // Absolute page points, NOT relative to the overlay bounding box.
            PageOverlay(id: UUID(), kind: .ink, text: nil, points: points,
                        x: 0, y: 0, width: 1, height: 1, lineWidth: lineWidth)
        }
    }
}

struct EditorOCRTranscript: View {
    @Environment(\.dismiss) private var dismiss
    let text: String
    let busy: Bool
    @State private var copied = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if busy { ProgressView("Reconhecendo no dispositivo...") }
                ScrollView {
                    Text(text.isEmpty && !busy ? "Nenhum texto foi reconhecido nesta pagina." : text)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding()
                        .accessibilityIdentifier("editor.ocr.transcript")
                }
                HStack {
                    Button(copied ? "Copiado" : "Copiar", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = text; copied = true
                    }.accessibilityIdentifier("editor.ocr.copy")
                    ShareLink(item: text) { Label("Compartilhar", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("editor.ocr.share")
                }.disabled(busy || text.isEmpty).padding(.bottom)
                Text("OCR local. Compartilhar abre as opcoes do sistema; nao ha envio automatico.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }.navigationTitle("Texto reconhecido").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fechar") { dismiss() } } }
            .tint(.green)
        }
    }
}
