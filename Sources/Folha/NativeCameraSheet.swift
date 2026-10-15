import SwiftUI
import AVFoundation
import UIKit

// Independent capture. Mode IDs follow the recovered configuration; this is not
// the original camera implementation or a claim of complete runtime equivalence.
struct NativeCameraSheet: UIViewControllerRepresentable {
    var singleOnly = false
    let onFinish: ([Data]) -> Void
    let onCancel: () -> Void
    let onError: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerCaptureController {
        let controller = ScannerCaptureController()
        controller.singleOnly = singleOnly
        controller.onFinish = onFinish
        controller.onCancel = onCancel
        controller.onError = onError
        return controller
    }
    func updateUIViewController(_ controller: ScannerCaptureController, context: Context) { }
    static func dismantleUIViewController(_ controller: ScannerCaptureController, coordinator: ()) { controller.stop() }
}

final class ScannerCaptureController: UIViewController, AVCapturePhotoCaptureDelegate, AVCaptureMetadataOutputObjectsDelegate {
    var singleOnly = false
    var onFinish: (([Data]) -> Void)?
    var onCancel: (() -> Void)?
    var onError: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let captureQueue = DispatchQueue(label: "com.valyc.scanner.camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var images: [Data] = []
    private var capturing = false
    private var ended = false
    private var flashOn = false
    private var mode = NativeScanConfiguration.CameraMode.singlePage
    private let shutter = CameraShutterButton(frame: .zero)
    private let finish = UIButton(type: .system)
    private let status = UILabel()
    private let modes = UISegmentedControl(items: ["Digitalizar", "Texto", "QR"])
    private let pageModes = UISegmentedControl(items: ["\u{00DA}nico", "Lote"])
    private let previewContainer = UIView()
    private let gridOverlay = UIView()
    private let gridLines = CAShapeLayer()
    private let panel = UIView()
    private let modeStrip = UIView()
    private let modeMarker = UIView()
    private let captureThumbnail = UIImageView()
    private let captureCount = UILabel()
    private let accent = UIColor(red: 0.12, green: 0.78, blue: 0.65, alpha: 1)
    private let qrText = UITextView()
    private let copyQR = UIButton(type: .system)

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        previewContainer.backgroundColor = .black
        previewContainer.clipsToBounds = true
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewContainer)
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        previewContainer.layer.addSublayer(layer)
        preview = layer
        configureControls()
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: .AVCaptureSessionWasInterrupted, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(resumed), name: .AVCaptureSessionInterruptionEnded, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(runtimeFailure(_:)), name: .AVCaptureSessionRuntimeError, object: session)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                guard let self = self else { return }
                if allowed { self.configureSession() }
                else { self.fail("Permita o acesso a camera nos Ajustes do iPhone.") }
            }
        default: fail("Permita o acesso a camera nos Ajustes do iPhone.")
        }
    }

    private func configureControls() {
        view.tintColor = .white
        panel.backgroundColor = .black
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.accessibilityLabel = "Cancelar captura"
        close.accessibilityIdentifier = "camera.cancel"
        close.addTarget(self, action: #selector(cancelCapture), for: .touchUpInside)
        let flash = UIButton(type: .system)
        flash.setImage(UIImage(systemName: "bolt.slash"), for: .normal)
        flash.accessibilityLabel = "Alternar flash"
        flash.accessibilityValue = "Desativado"
        flash.accessibilityIdentifier = "camera.flash"
        flash.addTarget(self, action: #selector(toggleFlash(_:)), for: .touchUpInside)
        let grid = UIButton(type: .system)
        grid.setImage(UIImage(systemName: "grid"), for: .normal)
        grid.isSelected = true
        grid.tintColor = accent
        grid.accessibilityLabel = "Grade de enquadramento"
        grid.accessibilityValue = "Ativada"
        grid.accessibilityIdentifier = "camera.grid"
        grid.addTarget(self, action: #selector(toggleGrid(_:)), for: .touchUpInside)
        for button in [close, flash, grid] {
            button.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 20, weight: .regular), forImageIn: .normal)
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }
        let header = UIStackView(arrangedSubviews: [close, UIView(), flash, grid])
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        gridOverlay.isUserInteractionEnabled = false
        gridOverlay.translatesAutoresizingMaskIntoConstraints = false
        gridLines.strokeColor = UIColor.white.withAlphaComponent(0.24).cgColor
        gridLines.lineWidth = 0.5
        gridLines.fillColor = nil
        gridOverlay.layer.addSublayer(gridLines)
        previewContainer.addSubview(gridOverlay)
        let hint = UIView()
        hint.backgroundColor = UIColor.black.withAlphaComponent(0.68)
        hint.layer.cornerRadius = 17
        hint.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(hint)
        status.text = "Preparando camera..."
        status.textColor = .white
        status.textAlignment = .center
        status.font = .preferredFont(forTextStyle: .caption1)
        status.adjustsFontForContentSizeCategory = true
        status.numberOfLines = 0
        status.translatesAutoresizingMaskIntoConstraints = false
        hint.addSubview(status)

        pageModes.selectedSegmentIndex = 0
        pageModes.backgroundColor = UIColor.black.withAlphaComponent(0.64)
        pageModes.selectedSegmentTintColor = UIColor.white.withAlphaComponent(0.24)
        pageModes.setTitleTextAttributes([.foregroundColor: UIColor.white,
            .font: UIFont.systemFont(ofSize: 12, weight: .medium)], for: .normal)
        pageModes.setTitleTextAttributes([.foregroundColor: UIColor.white,
            .font: UIFont.systemFont(ofSize: 12, weight: .semibold)], for: .selected)
        pageModes.layer.cornerRadius = 16
        pageModes.clipsToBounds = true
        pageModes.accessibilityIdentifier = "camera.page-mode"
        pageModes.addTarget(self, action: #selector(changeMode), for: .valueChanged)
        pageModes.isHidden = singleOnly
        pageModes.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(pageModes)

        modeStrip.backgroundColor = UIColor(white: 0.035, alpha: 1)
        modeStrip.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(modeStrip)
        modes.selectedSegmentIndex = 0
        modes.backgroundColor = .clear
        modes.selectedSegmentTintColor = .clear
        modes.setBackgroundImage(UIImage(), for: .normal, barMetrics: .default)
        modes.setDividerImage(UIImage(), forLeftSegmentState: .normal, rightSegmentState: .normal, barMetrics: .default)
        modes.setTitleTextAttributes([.foregroundColor: UIColor.white,
            .font: UIFont.systemFont(ofSize: 13, weight: .regular)], for: .normal)
        modes.setTitleTextAttributes([.foregroundColor: accent,
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold)], for: .selected)
        modes.accessibilityIdentifier = "camera.mode"
        modes.addTarget(self, action: #selector(changeMode), for: .valueChanged)
        modes.isHidden = singleOnly
        modes.translatesAutoresizingMaskIntoConstraints = false
        modeStrip.addSubview(modes)
        modeMarker.backgroundColor = accent
        modeMarker.layer.cornerRadius = 1.5
        modeMarker.isHidden = singleOnly
        modeMarker.isUserInteractionEnabled = false
        modeStrip.addSubview(modeMarker)

        shutter.accessibilityLabel = "Capturar pagina"
        shutter.accessibilityIdentifier = "camera.shutter"
        shutter.addTarget(self, action: #selector(takePhoto), for: .touchUpInside)
        shutter.isEnabled = false
        shutter.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(shutter)
        finish.setImage(UIImage(systemName: "photo.on.rectangle"), for: .normal)
        finish.accessibilityLabel = "Concluir lote"
        finish.accessibilityValue = "0 paginas capturadas"
        finish.accessibilityHint = "Abre as paginas capturadas no editor."
        finish.accessibilityIdentifier = "camera.finish"
        finish.isEnabled = false
        finish.addTarget(self, action: #selector(finishCapture), for: .touchUpInside)
        finish.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(finish)
        captureThumbnail.contentMode = .scaleAspectFill
        captureThumbnail.clipsToBounds = true
        captureThumbnail.layer.cornerRadius = 6
        captureThumbnail.layer.borderWidth = 1
        captureThumbnail.layer.borderColor = UIColor.white.withAlphaComponent(0.65).cgColor
        captureThumbnail.isHidden = true
        captureThumbnail.isAccessibilityElement = false
        captureThumbnail.translatesAutoresizingMaskIntoConstraints = false
        finish.addSubview(captureThumbnail)
        captureCount.textColor = .white
        captureCount.backgroundColor = accent
        captureCount.font = .systemFont(ofSize: 12, weight: .bold)
        captureCount.textAlignment = .center
        captureCount.layer.cornerRadius = 12
        captureCount.clipsToBounds = true
        captureCount.isHidden = true
        captureCount.isAccessibilityElement = false
        captureCount.translatesAutoresizingMaskIntoConstraints = false
        finish.addSubview(captureCount)

        qrText.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        qrText.textColor = .white
        qrText.font = .preferredFont(forTextStyle: .body)
        qrText.isEditable = false
        qrText.isHidden = true
        qrText.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(qrText)
        copyQR.setTitle("Copiar codigo", for: .normal)
        copyQR.isHidden = true
        copyQR.translatesAutoresizingMaskIntoConstraints = false
        copyQR.addTarget(self, action: #selector(copyCode), for: .touchUpInside)
        view.addSubview(copyQR)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            header.heightAnchor.constraint(equalToConstant: 44),
            previewContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            previewContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewContainer.bottomAnchor.constraint(equalTo: panel.topAnchor),
            gridOverlay.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            gridOverlay.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            gridOverlay.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            gridOverlay.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            hint.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 22),
            hint.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: previewContainer.leadingAnchor, constant: 24),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: previewContainer.trailingAnchor, constant: -24),
            hint.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            status.leadingAnchor.constraint(equalTo: hint.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: hint.trailingAnchor, constant: -16),
            status.topAnchor.constraint(equalTo: hint.topAnchor, constant: 10),
            status.bottomAnchor.constraint(equalTo: hint.bottomAnchor, constant: -10),
            pageModes.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            pageModes.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -12),
            pageModes.widthAnchor.constraint(equalToConstant: 128),
            pageModes.heightAnchor.constraint(equalToConstant: 32),
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor), panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            modeStrip.topAnchor.constraint(equalTo: panel.topAnchor),
            modeStrip.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            modeStrip.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            modeStrip.heightAnchor.constraint(equalToConstant: 44),
            modes.topAnchor.constraint(equalTo: modeStrip.topAnchor),
            modes.bottomAnchor.constraint(equalTo: modeStrip.bottomAnchor),
            modes.leadingAnchor.constraint(equalTo: modeStrip.leadingAnchor, constant: 16),
            modes.trailingAnchor.constraint(equalTo: modeStrip.trailingAnchor, constant: -16),
            shutter.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            shutter.topAnchor.constraint(equalTo: modeStrip.bottomAnchor, constant: 24),
            shutter.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -38),
            shutter.widthAnchor.constraint(equalToConstant: 72), shutter.heightAnchor.constraint(equalToConstant: 72),
            finish.centerXAnchor.constraint(equalTo: shutter.centerXAnchor, constant: 112),
            finish.centerYAnchor.constraint(equalTo: shutter.centerYAnchor),
            finish.widthAnchor.constraint(equalToConstant: 64), finish.heightAnchor.constraint(equalToConstant: 64),
            captureThumbnail.centerXAnchor.constraint(equalTo: finish.centerXAnchor),
            captureThumbnail.centerYAnchor.constraint(equalTo: finish.centerYAnchor),
            captureThumbnail.widthAnchor.constraint(equalToConstant: 48), captureThumbnail.heightAnchor.constraint(equalToConstant: 48),
            captureCount.trailingAnchor.constraint(equalTo: finish.trailingAnchor),
            captureCount.topAnchor.constraint(equalTo: finish.topAnchor),
            captureCount.widthAnchor.constraint(equalToConstant: 24), captureCount.heightAnchor.constraint(equalToConstant: 24),
            qrText.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor), qrText.heightAnchor.constraint(equalToConstant: 150),
            qrText.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            qrText.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            copyQR.topAnchor.constraint(equalTo: qrText.bottomAnchor, constant: 8),
            copyQR.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
    }

    private func configureSession() {
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                    throw ScanFailure.message("Camera traseira indisponivel. No simulador, importe fotos.")
                }
                let input = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                guard self.session.canAddInput(input), self.session.canAddOutput(self.photoOutput) else {
                    self.session.commitConfiguration()
                    throw ScanFailure.message("Nao foi possivel configurar a captura.")
                }
                self.session.addInput(input)
                self.session.addOutput(self.photoOutput)
                if self.session.canAddOutput(self.metadataOutput) {
                    self.session.addOutput(self.metadataOutput)
                    self.metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
                    if self.metadataOutput.availableMetadataObjectTypes.contains(.qr) { self.metadataOutput.metadataObjectTypes = [.qr] }
                }
                self.photoOutput.maxPhotoQualityPrioritization = .quality
                self.session.commitConfiguration()
                self.session.startRunning()
                DispatchQueue.main.async {
                    guard !self.ended else { self.stop(); return }
                    self.shutter.isEnabled = true
                    self.status.text = "Enquadre o documento. O recorte sera ajustado no editor."
                }
            } catch { self.fail(error.localizedDescription) }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview?.frame = previewContainer.bounds
        gridLines.frame = gridOverlay.bounds
        let lines = UIBezierPath()
        for division in 1...2 {
            let fraction = CGFloat(division) / 3
            let x = gridOverlay.bounds.width * fraction
            let y = gridOverlay.bounds.height * fraction
            lines.move(to: CGPoint(x: x, y: 0))
            lines.addLine(to: CGPoint(x: x, y: gridOverlay.bounds.height))
            lines.move(to: CGPoint(x: 0, y: y))
            lines.addLine(to: CGPoint(x: gridOverlay.bounds.width, y: y))
        }
        gridLines.path = lines.cgPath
        CATransaction.commit()
        let segmentWidth = modes.bounds.width / CGFloat(modes.numberOfSegments)
        modeMarker.frame = CGRect(x: modes.frame.minX + segmentWidth * (CGFloat(modes.selectedSegmentIndex) + 0.5) - 13,
                                  y: 0, width: 26, height: 3)
        if let connection = preview?.connection, connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
    }
    @objc private func takePhoto() {
        guard !ended, !capturing, mode != .qrCode, images.count < 50 else { return }
        capturing = true
        shutter.isSelected = true
        shutter.isEnabled = false
        finish.isEnabled = false
        modes.isEnabled = false
        pageModes.isEnabled = false
        let useFlash = flashOn
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.photoQualityPrioritization = .quality
            if self.photoOutput.supportedFlashModes.contains(.on) { settings.flashMode = useFlash ? .on : .off }
            if let connection = self.photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        DispatchQueue.main.async {
            guard !self.ended else { return }
            self.capturing = false
            self.shutter.isSelected = false
            self.modes.isEnabled = true
            self.pageModes.isEnabled = true
            self.shutter.isEnabled = true
            if let error = error { self.status.text = error.localizedDescription; self.finish.isEnabled = !self.images.isEmpty; return }
            guard let data = data else { self.status.text = "Captura sem imagem. Tente novamente."; self.finish.isEnabled = !self.images.isEmpty; return }
            self.images.append(data)
            self.captureThumbnail.image = UIImage(data: data)
            self.captureThumbnail.isHidden = false
            self.captureCount.text = "\(self.images.count)"
            self.captureCount.isHidden = false
            self.finish.setImage(nil, for: .normal)
            self.finish.accessibilityValue = "\(self.images.count) paginas capturadas"
            self.finish.isEnabled = true
            self.status.text = "\(self.images.count) paginas capturadas"
            if self.mode != .multiplePages || self.singleOnly { self.finishCapture() }
            else if self.images.count >= 50 { self.shutter.isEnabled = false; self.status.text = "50 paginas neste lote. Conclua e continue no documento." }
        }
    }
    @objc private func changeMode() {
        let documentMode: NativeScanConfiguration.CameraMode = pageModes.selectedSegmentIndex == 1 ? .multiplePages : .singlePage
        let available: [NativeScanConfiguration.CameraMode] = [documentMode, .textRecognition, .qrCode]
        mode = available[modes.selectedSegmentIndex]
        let qr = mode == .qrCode
        pageModes.isHidden = singleOnly || modes.selectedSegmentIndex != 0
        shutter.isHidden = qr
        qrText.isHidden = !qr
        copyQR.isHidden = !qr
        status.text = qr ? "Aponte para um QR. Links nao sao abertos automaticamente." : "Enquadre o documento e toque para capturar."
        view.setNeedsLayout()
    }
    @objc private func toggleFlash(_ sender: UIButton) {
        flashOn.toggle()
        sender.setImage(UIImage(systemName: flashOn ? "bolt.fill" : "bolt.slash"), for: .normal)
        sender.tintColor = flashOn ? accent : .white
        sender.accessibilityValue = flashOn ? "Ativado" : "Desativado"
    }
    @objc private func toggleGrid(_ sender: UIButton) {
        gridOverlay.isHidden.toggle()
        sender.isSelected = !gridOverlay.isHidden
        sender.tintColor = gridOverlay.isHidden ? .white : accent
        sender.accessibilityValue = gridOverlay.isHidden ? "Desativada" : "Ativada"
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !ended, mode == .qrCode,
              let code = objects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first?.stringValue else { return }
        qrText.text = code
        status.text = "QR reconhecido"
    }
    @objc private func copyCode() { if !qrText.text.isEmpty { UIPasteboard.general.string = qrText.text; status.text = "Codigo copiado" } }
    @objc private func finishCapture() {
        guard !ended, !capturing, !images.isEmpty else { return }
        ended = true; stop(); onFinish?(images)
    }
    @objc private func cancelCapture() {
        guard !ended else { return }
        if images.isEmpty { ended = true; stop(); onCancel?(); return }
        let alert = UIAlertController(title: "Descartar este lote?", message: "As \(images.count) paginas ainda nao foram salvas.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Continuar", style: .cancel))
        alert.addAction(UIAlertAction(title: "Descartar", style: .destructive) { _ in self.ended = true; self.stop(); self.onCancel?() })
        present(alert, animated: true)
    }
    @objc private func interrupted() { DispatchQueue.main.async { self.shutter.isEnabled = false; self.status.text = "Camera interrompida. Aguarde retornar ao aplicativo." } }
    @objc private func resumed() { DispatchQueue.main.async { if !self.ended { self.shutter.isEnabled = !self.capturing; self.status.text = "Camera pronta" } } }
    @objc private func runtimeFailure(_ notification: Notification) {
        let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "A camera foi interrompida."
        DispatchQueue.main.async {
            self.shutter.isEnabled = false
            self.status.text = message + (self.images.isEmpty ? " Feche e tente novamente." : " Conclua para salvar as paginas ja capturadas.")
        }
    }
    private func fail(_ message: String) { DispatchQueue.main.async { guard !self.ended else { return }; self.ended = true; self.stop(); self.onError?(message) } }
    func stop() { captureQueue.async { [session] in if session.isRunning { session.stopRunning() } } }
    deinit { NotificationCenter.default.removeObserver(self) }
}

// Capture feedback only: the teal ring does not imply automatic edge detection.
private final class CameraShutterButton: UIButton {
    private let disc = CALayer()
    private let ring = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        ring.fillColor = nil
        ring.lineWidth = 3
        layer.addSublayer(disc)
        layer.addSublayer(ring)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override var isEnabled: Bool { didSet { updateAppearance() } }
    override var isHighlighted: Bool { didSet { updateAppearance() } }
    override var isSelected: Bool { didSet { updateAppearance() } }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.frame = bounds.insetBy(dx: 8, dy: 8)
        disc.cornerRadius = disc.bounds.width / 2
        ring.frame = bounds
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).cgPath
        CATransaction.commit()
    }

    private func updateAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.backgroundColor = UIColor.white.cgColor
        ring.strokeColor = (isHighlighted || isSelected
            ? UIColor(red: 0.12, green: 0.78, blue: 0.65, alpha: 1)
            : UIColor(white: 0.26, alpha: 1)).cgColor
        alpha = isEnabled || isSelected ? 1 : 0.45
        CATransaction.commit()
    }
}
