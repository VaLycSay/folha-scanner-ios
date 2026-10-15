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
    private let shutter = UIButton(type: .system)
    private let finish = UIButton(type: .system)
    private let status = UILabel()
    private let modes = UISegmentedControl(items: ["Unica", "Lote", "Texto", "QR"])
    private let panel = UIView()
    private let qrText = UITextView()
    private let copyQR = UIButton(type: .system)

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
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
        panel.backgroundColor = UIColor.black.withAlphaComponent(0.86)
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        let close = UIButton(type: .system)
        close.setTitle("Cancelar", for: .normal)
        close.addTarget(self, action: #selector(cancelCapture), for: .touchUpInside)
        let flash = UIButton(type: .system)
        flash.setImage(UIImage(systemName: "bolt.slash"), for: .normal)
        flash.accessibilityLabel = "Alternar flash"
        flash.addTarget(self, action: #selector(toggleFlash(_:)), for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [close, UIView(), flash])
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        status.text = "Preparando camera..."
        status.textColor = .white
        status.textAlignment = .center
        status.font = .preferredFont(forTextStyle: .caption1)
        status.numberOfLines = 2
        modes.selectedSegmentIndex = 0
        modes.selectedSegmentTintColor = UIColor(red: 0.08, green: 0.61, blue: 0.39, alpha: 1)
        modes.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        modes.addTarget(self, action: #selector(changeMode), for: .valueChanged)
        modes.isHidden = singleOnly
        shutter.backgroundColor = .white
        shutter.layer.cornerRadius = 34
        shutter.layer.borderWidth = 5
        shutter.layer.borderColor = UIColor.gray.cgColor
        shutter.accessibilityLabel = "Capturar pagina"
        shutter.accessibilityIdentifier = "camera.shutter"
        shutter.addTarget(self, action: #selector(takePhoto), for: .touchUpInside)
        shutter.isEnabled = false
        finish.setTitle("Concluir (0)", for: .normal)
        finish.isEnabled = false
        finish.addTarget(self, action: #selector(finishCapture), for: .touchUpInside)
        let row = UIStackView(arrangedSubviews: [UIView(), shutter, UIView(), finish])
        row.alignment = .center
        row.spacing = 20
        let column = UIStackView(arrangedSubviews: [status, modes, row])
        column.axis = .vertical
        column.spacing = 18
        column.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(column)
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
        view.tintColor = .white
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor), panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            column.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
            column.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18),
            column.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18),
            column.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
            shutter.widthAnchor.constraint(equalToConstant: 68), shutter.heightAnchor.constraint(equalToConstant: 68),
            qrText.centerYAnchor.constraint(equalTo: view.centerYAnchor), qrText.heightAnchor.constraint(equalToConstant: 150),
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
        preview?.frame = view.bounds
        if let connection = preview?.connection, connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
    }
    @objc private func takePhoto() {
        guard !ended, !capturing, mode != .qrCode, images.count < 50 else { return }
        capturing = true
        shutter.isEnabled = false
        finish.isEnabled = false
        modes.isEnabled = false
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
            self.modes.isEnabled = true
            self.shutter.isEnabled = true
            if let error = error { self.status.text = error.localizedDescription; self.finish.isEnabled = !self.images.isEmpty; return }
            guard let data = data else { self.status.text = "Captura sem imagem. Tente novamente."; self.finish.isEnabled = !self.images.isEmpty; return }
            self.images.append(data)
            self.finish.setTitle("Concluir (\(self.images.count))", for: .normal)
            self.finish.isEnabled = true
            self.status.text = "\(self.images.count) paginas capturadas"
            if self.mode != .multiplePages || self.singleOnly { self.finishCapture() }
            else if self.images.count >= 50 { self.shutter.isEnabled = false; self.status.text = "50 paginas neste lote. Conclua e continue no documento." }
        }
    }
    @objc private func changeMode() {
        let available: [NativeScanConfiguration.CameraMode] = [.singlePage, .multiplePages, .textRecognition, .qrCode]
        mode = available[modes.selectedSegmentIndex]
        let qr = mode == .qrCode
        shutter.isHidden = qr
        qrText.isHidden = !qr
        copyQR.isHidden = !qr
        status.text = qr ? "Aponte para um QR. Links nao sao abertos automaticamente." : "Enquadre o documento e toque para capturar."
    }
    @objc private func toggleFlash(_ sender: UIButton) {
        flashOn.toggle()
        sender.setImage(UIImage(systemName: flashOn ? "bolt.fill" : "bolt.slash"), for: .normal)
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
