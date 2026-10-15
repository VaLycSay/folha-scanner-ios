import SwiftUI
import AVFoundation
import UIKit
import Vision
import VisionKit

enum CameraWorkflowMode: Int, CaseIterable {
    case ocr = 0
    case idCard = 1
    case signature = 2
    case scan = 3
    case toWord = 4
    case timestamp = 5
    case toExcel = 6
    case qrCode = 7

    var title: String {
        switch self {
        case .ocr: return "Extrair texto"
        case .idCard: return "Cartões ID"
        case .signature: return "Sign"
        case .scan: return "Digitalizar"
        case .toWord: return "Para Word"
        case .timestamp: return "Carimbo de data"
        case .toExcel: return "Para Excel"
        case .qrCode: return "QR Code"
        }
    }
}

struct NativeCameraSheet: UIViewControllerRepresentable {
    var singleOnly = false
    var initialWorkflow: CameraWorkflowMode = .scan
    var onFinishPages: (([CapturedScanPage], CameraWorkflowMode) -> Void)? = nil
    var onFinish: ([Data]) -> Void = { _ in }
    let onCancel: () -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerCaptureController {
        let controller = ScannerCaptureController()
        controller.singleOnly = singleOnly
        controller.workflowMode = initialWorkflow
        controller.onFinishPages = onFinishPages
        controller.onFinish = onFinish
        controller.onCancel = onCancel
        controller.onError = onError
        return controller
    }

    func updateUIViewController(_ controller: ScannerCaptureController, context: Context) {}

    static func dismantleUIViewController(_ controller: ScannerCaptureController, coordinator: ()) {
        controller.stop()
    }
}

final class ScannerCaptureController: UIViewController,
    AVCapturePhotoCaptureDelegate,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureMetadataOutputObjectsDelegate,
    VNDocumentCameraViewControllerDelegate
{
    var singleOnly = false
    var workflowMode: CameraWorkflowMode = .scan
    var onFinishPages: (([CapturedScanPage], CameraWorkflowMode) -> Void)?
    var onFinish: (([Data]) -> Void)?
    var onCancel: (() -> Void)?
    var onError: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let captureQueue = DispatchQueue(label: "com.valyc.scanner.camera", qos: .userInitiated)
    private let visionQueue = DispatchQueue(label: "com.valyc.scanner.vision", qos: .userInitiated)

    private var preview: AVCaptureVideoPreviewLayer?
    private let gridLayer = CAShapeLayer()
    private let quadLayer = CAShapeLayer()
    private var cornerDots: [CAShapeLayer] = []
    private let autoRingTrack = CAShapeLayer()
    private let autoRingProgress = CAShapeLayer()

    private var capturedPages: [CapturedScanPage] = []
    private var idCardFrontImage: UIImage?
    private var capturing = false
    private var ended = false
    private var flashOn = false
    private var batchMode = false
    private var autoCaptureEnabled = true
    private var selectedFilter: PageFilter = .clean

    // Vision live tracking state
    private var isDetectingFrame = false
    private var lastDetectionTime: CFTimeInterval = 0
    private var smoothedCorners: PageCorners?
    private var lockedCaptureCorners: PageCorners?
    private var stabilityProgress: Double = 0
    private var cooldownUntil: CFTimeInterval = 0
    private var missedFrames = 0

    // UI Elements
    private let topBar = UIView()
    private let autoButton = UIButton(type: .system)
    private let filterButton = UIButton(type: .system)
    private let guidancePill = UIView()
    private let guidanceLabel = UILabel()
    private let idGuideBox = UIView()
    private let idGuideLabel = UILabel()
    private let timestampCard = UIView()
    private let timestampLabel = UILabel()
    private var timestampTimer: Timer?

    private let panel = UIView()
    private let batchToggle = UISegmentedControl(items: ["Único", "Lote"])
    private let modeScroll = UIScrollView()
    private let modeStack = UIStackView()
    private var modeButtons: [UIButton] = []
    private let shutterContainer = UIView()
    private let shutter = UIButton(type: .system)
    private let finish = UIButton(type: .system)
    private let qrText = UITextView()
    private let copyQR = UIButton(type: .system)

    private let accentColor = UIColor(red: 0.09, green: 0.79, blue: 0.61, alpha: 1.0)

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer

        configureOverlays()
        configureControls()
        updateWorkflowUI()

        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: .AVCaptureSessionWasInterrupted, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(resumed), name: .AVCaptureSessionInterruptionEnded, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(runtimeFailure(_:)), name: .AVCaptureSessionRuntimeError, object: session)

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                guard let self else { return }
                if allowed { self.configureSession() }
                else { self.fail("Permita o acesso à câmera nos Ajustes do iPhone.") }
            }
        default:
            fail("Permita o acesso à câmera nos Ajustes do iPhone.")
        }
    }

    private func configureOverlays() {
        gridLayer.strokeColor = UIColor.white.withAlphaComponent(0.24).cgColor
        gridLayer.fillColor = UIColor.clear.cgColor
        gridLayer.lineWidth = 0.8
        view.layer.addSublayer(gridLayer)

        quadLayer.fillColor = accentColor.withAlphaComponent(0.24).cgColor
        quadLayer.strokeColor = accentColor.cgColor
        quadLayer.lineWidth = 3.0
        quadLayer.lineJoin = .round
        quadLayer.isHidden = true
        view.layer.addSublayer(quadLayer)

        for _ in 0..<4 {
            let dot = CAShapeLayer()
            dot.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
            dot.path = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 14, height: 14)).cgPath
            dot.fillColor = accentColor.cgColor
            dot.strokeColor = UIColor.white.cgColor
            dot.lineWidth = 2.2
            dot.isHidden = true
            view.layer.addSublayer(dot)
            cornerDots.append(dot)
        }
    }

    private func configureControls() {
        view.tintColor = .white

        // Top Bar
        topBar.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        close.accessibilityLabel = "Cancelar"
        close.addTarget(self, action: #selector(cancelCapture), for: .touchUpInside)

        let flash = UIButton(type: .system)
        flash.setImage(UIImage(systemName: "bolt.slash.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)), for: .normal)
        flash.accessibilityLabel = "Alternar flash"
        flash.addTarget(self, action: #selector(toggleFlash(_:)), for: .touchUpInside)

        let hdBadge = UILabel()
        hdBadge.text = " HD "
        hdBadge.font = .systemFont(ofSize: 11, weight: .bold)
        hdBadge.textColor = .white
        hdBadge.layer.borderColor = UIColor.white.withAlphaComponent(0.75).cgColor
        hdBadge.layer.borderWidth = 1.2
        hdBadge.layer.cornerRadius = 4

        autoButton.setTitle(" Auto: ON ", for: .normal)
        autoButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
        autoButton.backgroundColor = accentColor
        autoButton.setTitleColor(.white, for: .normal)
        autoButton.layer.cornerRadius = 12
        autoButton.addTarget(self, action: #selector(toggleAutoCapture), for: .touchUpInside)

        let visionKitBtn = UIButton(type: .system)
        visionKitBtn.setImage(UIImage(systemName: "doc.viewfinder.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
        visionKitBtn.accessibilityLabel = "Scanner Nativo iOS"
        visionKitBtn.addTarget(self, action: #selector(openSystemDocumentCamera), for: .touchUpInside)

        let headerStack = UIStackView(arrangedSubviews: [close, UIView(), flash, hdBadge, autoButton, visionKitBtn])
        headerStack.alignment = .center
        headerStack.spacing = 14
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(headerStack)

        // Floating Guidance Pill ("Coloque a página inteira na tela da câmera")
        guidancePill.backgroundColor = UIColor.black.withAlphaComponent(0.68)
        guidancePill.layer.cornerRadius = 18
        guidancePill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(guidancePill)

        let pillIcon = UIImageView(image: UIImage(systemName: "viewfinder", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)))
        pillIcon.tintColor = accentColor
        guidanceLabel.text = "Coloque a página inteira na tela da câmera"
        guidanceLabel.textColor = .white
        guidanceLabel.font = .systemFont(ofSize: 13, weight: .medium)
        guidanceLabel.numberOfLines = 1
        let pillStack = UIStackView(arrangedSubviews: [pillIcon, guidanceLabel])
        pillStack.alignment = .center
        pillStack.spacing = 8
        pillStack.translatesAutoresizingMaskIntoConstraints = false
        guidancePill.addSubview(pillStack)

        // ID Card Frame Guide (hidden unless Cartões ID is selected)
        idGuideBox.layer.borderColor = accentColor.cgColor
        idGuideBox.layer.borderWidth = 2.2
        idGuideBox.layer.cornerRadius = 14
        idGuideBox.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        idGuideBox.isHidden = true
        idGuideBox.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(idGuideBox)

        idGuideLabel.text = "Frente do Documento (1/2)"
        idGuideLabel.textColor = .white
        idGuideLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        idGuideLabel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        idGuideLabel.layer.cornerRadius = 8
        idGuideLabel.clipsToBounds = true
        idGuideLabel.textAlignment = .center
        idGuideLabel.translatesAutoresizingMaskIntoConstraints = false
        idGuideBox.addSubview(idGuideLabel)

        // Timestamp Watermark Card (hidden unless Carimbo de data is selected)
        timestampCard.backgroundColor = UIColor.black.withAlphaComponent(0.62)
        timestampCard.layer.cornerRadius = 10
        timestampCard.layer.borderColor = accentColor.withAlphaComponent(0.8).cgColor
        timestampCard.layer.borderWidth = 1.2
        timestampCard.isHidden = true
        timestampCard.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(timestampCard)

        timestampLabel.numberOfLines = 3
        timestampLabel.textColor = .white
        timestampLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        timestampLabel.translatesAutoresizingMaskIntoConstraints = false
        timestampCard.addSubview(timestampLabel)
        updateTimestampText()
        timestampTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateTimestampText()
        }

        // Bottom Panel
        panel.backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 0.94)
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)

        batchToggle.selectedSegmentIndex = 0
        batchToggle.selectedSegmentTintColor = accentColor
        batchToggle.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        batchToggle.setTitleTextAttributes([.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 12, weight: .semibold)], for: .normal)
        batchToggle.addTarget(self, action: #selector(changeBatchMode), for: .valueChanged)
        batchToggle.isHidden = singleOnly
        batchToggle.translatesAutoresizingMaskIntoConstraints = false

        // Mode Strip
        modeScroll.showsHorizontalScrollIndicator = false
        modeScroll.translatesAutoresizingMaskIntoConstraints = false
        modeStack.axis = .horizontal
        modeStack.spacing = 18
        modeStack.alignment = .center
        modeStack.translatesAutoresizingMaskIntoConstraints = false
        modeScroll.addSubview(modeStack)

        for mode in CameraWorkflowMode.allCases {
            let btn = UIButton(type: .system)
            btn.tag = mode.rawValue
            btn.setTitle(mode.title, for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 13, weight: mode == workflowMode ? .bold : .medium)
            btn.setTitleColor(mode == workflowMode ? accentColor : UIColor.white.withAlphaComponent(0.65), for: .normal)
            btn.addTarget(self, action: #selector(selectWorkflowMode(_:)), for: .touchUpInside)
            modeButtons.append(btn)
            modeStack.addArrangedSubview(btn)
        }

        // Filter Preset Button
        filterButton.setTitle("Cor Mágica", for: .normal)
        filterButton.setImage(UIImage(systemName: "wand.and.stars"), for: .normal)
        filterButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        filterButton.tintColor = accentColor
        filterButton.addTarget(self, action: #selector(cycleFilterPreset), for: .touchUpInside)

        // Shutter with Auto-Countdown Ring
        shutterContainer.translatesAutoresizingMaskIntoConstraints = false
        let ringCenter = CGPoint(x: 42, y: 42)
        let ringPath = UIBezierPath(arcCenter: ringCenter, radius: 38, startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true).cgPath
        autoRingTrack.path = ringPath
        autoRingTrack.strokeColor = UIColor.white.withAlphaComponent(0.28).cgColor
        autoRingTrack.fillColor = UIColor.clear.cgColor
        autoRingTrack.lineWidth = 4.0
        shutterContainer.layer.addSublayer(autoRingTrack)

        autoRingProgress.path = ringPath
        autoRingProgress.strokeColor = accentColor.cgColor
        autoRingProgress.fillColor = UIColor.clear.cgColor
        autoRingProgress.lineWidth = 4.5
        autoRingProgress.lineCap = .round
        autoRingProgress.strokeEnd = 0
        shutterContainer.layer.addSublayer(autoRingProgress)

        shutter.backgroundColor = .white
        shutter.layer.cornerRadius = 31
        shutter.layer.borderWidth = 3
        shutter.layer.borderColor = accentColor.cgColor
        shutter.accessibilityLabel = "Capturar pagina"
        shutter.accessibilityIdentifier = "camera.shutter"
        shutter.addTarget(self, action: #selector(manualShutterTapped), for: .touchUpInside)
        shutter.isEnabled = false
        shutter.translatesAutoresizingMaskIntoConstraints = false
        shutterContainer.addSubview(shutter)

        finish.setTitle("Concluir (0)", for: .normal)
        finish.titleLabel?.font = .systemFont(ofSize: 13, weight: .bold)
        finish.backgroundColor = accentColor.withAlphaComponent(0.22)
        finish.setTitleColor(accentColor, for: .normal)
        finish.setTitleColor(UIColor.white.withAlphaComponent(0.35), for: .disabled)
        finish.layer.cornerRadius = 16
        finish.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        finish.isEnabled = false
        finish.addTarget(self, action: #selector(finishCapture), for: .touchUpInside)

        let bottomControlsRow = UIStackView(arrangedSubviews: [filterButton, UIView(), shutterContainer, UIView(), finish])
        bottomControlsRow.alignment = .center
        bottomControlsRow.translatesAutoresizingMaskIntoConstraints = false

        let batchRow = UIStackView(arrangedSubviews: [UIView(), batchToggle, UIView()])
        batchRow.alignment = .center

        let column = UIStackView(arrangedSubviews: [batchRow, modeScroll, bottomControlsRow])
        column.axis = .vertical
        column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(column)

        // QR Code Result View
        qrText.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        qrText.textColor = .white
        qrText.font = .preferredFont(forTextStyle: .body)
        qrText.layer.cornerRadius = 12
        qrText.isEditable = false
        qrText.isHidden = true
        qrText.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(qrText)

        copyQR.setTitle("Copiar código QR", for: .normal)
        copyQR.backgroundColor = accentColor
        copyQR.setTitleColor(.white, for: .normal)
        copyQR.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
        copyQR.layer.cornerRadius = 10
        copyQR.contentEdgeInsets = UIEdgeInsets(top: 10, left: 18, bottom: 10, right: 18)
        copyQR.isHidden = true
        copyQR.translatesAutoresizingMaskIntoConstraints = false
        copyQR.addTarget(self, action: #selector(copyCode), for: .touchUpInside)
        view.addSubview(copyQR)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            headerStack.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -10),
            headerStack.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 18),
            headerStack.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -18),

            guidancePill.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 14),
            guidancePill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            guidancePill.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
            pillStack.topAnchor.constraint(equalTo: guidancePill.topAnchor, constant: 8),
            pillStack.bottomAnchor.constraint(equalTo: guidancePill.bottomAnchor, constant: -8),
            pillStack.leadingAnchor.constraint(equalTo: guidancePill.leadingAnchor, constant: 14),
            pillStack.trailingAnchor.constraint(equalTo: guidancePill.trailingAnchor, constant: -14),

            idGuideBox.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            idGuideBox.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -35),
            idGuideBox.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.84),
            idGuideBox.heightAnchor.constraint(equalTo: idGuideBox.widthAnchor, multiplier: 0.63),
            idGuideLabel.topAnchor.constraint(equalTo: idGuideBox.topAnchor, constant: 12),
            idGuideLabel.centerXAnchor.constraint(equalTo: idGuideBox.centerXAnchor),
            idGuideLabel.widthAnchor.constraint(equalToConstant: 230),
            idGuideLabel.heightAnchor.constraint(equalToConstant: 28),

            timestampCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            timestampCard.bottomAnchor.constraint(equalTo: panel.topAnchor, constant: -18),
            timestampLabel.topAnchor.constraint(equalTo: timestampCard.topAnchor, constant: 10),
            timestampLabel.bottomAnchor.constraint(equalTo: timestampCard.bottomAnchor, constant: -10),
            timestampLabel.leadingAnchor.constraint(equalTo: timestampCard.leadingAnchor, constant: 12),
            timestampLabel.trailingAnchor.constraint(equalTo: timestampCard.trailingAnchor, constant: -12),

            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            column.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            column.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),

            batchToggle.widthAnchor.constraint(equalToConstant: 156),
            batchToggle.heightAnchor.constraint(equalToConstant: 28),

            modeScroll.heightAnchor.constraint(equalToConstant: 32),
            modeStack.topAnchor.constraint(equalTo: modeScroll.topAnchor),
            modeStack.bottomAnchor.constraint(equalTo: modeScroll.bottomAnchor),
            modeStack.leadingAnchor.constraint(equalTo: modeScroll.leadingAnchor, constant: 8),
            modeStack.trailingAnchor.constraint(equalTo: modeScroll.trailingAnchor, constant: -8),
            modeStack.heightAnchor.constraint(equalTo: modeScroll.heightAnchor),

            shutterContainer.widthAnchor.constraint(equalToConstant: 84),
            shutterContainer.heightAnchor.constraint(equalToConstant: 84),
            shutter.centerXAnchor.constraint(equalTo: shutterContainer.centerXAnchor),
            shutter.centerYAnchor.constraint(equalTo: shutterContainer.centerYAnchor),
            shutter.widthAnchor.constraint(equalToConstant: 62),
            shutter.heightAnchor.constraint(equalToConstant: 62),

            qrText.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            qrText.heightAnchor.constraint(equalToConstant: 150),
            qrText.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            qrText.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            copyQR.topAnchor.constraint(equalTo: qrText.bottomAnchor, constant: 10),
            copyQR.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
    }

    private func configureSession() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            do {
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                    throw ScanFailure.message("Câmera traseira indisponível. No simulador, importe fotos.")
                }
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    try? device.lockForConfiguration()
                    device.focusMode = .continuousAutoFocus
                    if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = true }
                    device.unlockForConfiguration()
                }
                let input = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                guard self.session.canAddInput(input), self.session.canAddOutput(self.photoOutput) else {
                    self.session.commitConfiguration()
                    throw ScanFailure.message("Não foi possível configurar a captura.")
                }
                self.session.addInput(input)
                self.session.addOutput(self.photoOutput)

                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                if self.session.canAddOutput(self.videoOutput) {
                    self.session.addOutput(self.videoOutput)
                    self.videoOutput.setSampleBufferDelegate(self, queue: self.visionQueue)
                    if let conn = self.videoOutput.connection(with: .video), conn.isVideoRotationAngleSupported(90) {
                        conn.videoRotationAngle = 90
                    }
                }

                if self.session.canAddOutput(self.metadataOutput) {
                    self.session.addOutput(self.metadataOutput)
                    self.metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
                    if self.metadataOutput.availableMetadataObjectTypes.contains(.qr) {
                        self.metadataOutput.metadataObjectTypes = [.qr]
                    }
                }
                self.photoOutput.maxPhotoQualityPrioritization = .quality
                self.session.commitConfiguration()
                self.session.startRunning()
                DispatchQueue.main.async {
                    guard !self.ended else { self.stop(); return }
                    self.shutter.isEnabled = true
                    self.updateGuidanceText()
                }
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        preview?.frame = bounds
        gridLayer.frame = bounds
        quadLayer.frame = bounds
        if let connection = preview?.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        drawRuleOfThirdsGrid(in: bounds)
    }

    private func drawRuleOfThirdsGrid(in bounds: CGRect) {
        let topInset = topBar.frame.maxY
        let bottomInset = panel.frame.minY > 0 ? panel.frame.minY : bounds.height - 190
        let area = CGRect(x: 0, y: topInset, width: bounds.width, height: max(100, bottomInset - topInset))
        let path = UIBezierPath()
        for i in 1...2 {
            let x = area.minX + area.width * CGFloat(i) / 3.0
            path.move(to: CGPoint(x: x, y: area.minY))
            path.addLine(to: CGPoint(x: x, y: area.maxY))
            let y = area.minY + area.height * CGFloat(i) / 3.0
            path.move(to: CGPoint(x: area.minX, y: y))
            path.addLine(to: CGPoint(x: area.maxX, y: y))
        }
        gridLayer.path = path.cgPath
    }

    // MARK: - Live Vision Page Detection & Auto-Shutter

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === videoOutput, !ended, !capturing, workflowMode != .qrCode else { return }
        let now = CACurrentMediaTime()
        guard now - lastDetectionTime >= 0.085, !isDetectingFrame else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        isDetectingFrame = true
        lastDetectionTime = now

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let orientation: CGImagePropertyOrientation = width > height ? .right : .up

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        var detected: PageCorners?

        let docReq = VNDetectDocumentSegmentationRequest()
        if (try? handler.perform([docReq])) != nil,
           let obs = docReq.results?.first, obs.confidence >= 0.55 {
            let candidate = PageCorners(
                topLeft: .init(obs.topLeft), topRight: .init(obs.topRight),
                bottomLeft: .init(obs.bottomLeft), bottomRight: .init(obs.bottomRight)
            )
            let area = Self.polygonArea(candidate)
            if area >= 0.07 && area <= 0.96 && EditorGeometry.isValid(candidate) {
                detected = candidate
            }
        }

        if detected == nil {
            let rectReq = VNDetectRectanglesRequest()
            rectReq.maximumObservations = 3
            rectReq.minimumConfidence = 0.35
            rectReq.minimumSize = 0.12
            rectReq.minimumAspectRatio = 0.15
            rectReq.quadratureTolerance = 35
            if (try? handler.perform([rectReq])) != nil,
               let best = (rectReq.results ?? []).first {
                let candidate = PageCorners(
                    topLeft: .init(best.topLeft), topRight: .init(best.topRight),
                    bottomLeft: .init(best.bottomLeft), bottomRight: .init(best.bottomRight)
                )
                let area = Self.polygonArea(candidate)
                if area >= 0.06 && area <= 0.96 && EditorGeometry.isValid(candidate) {
                    detected = candidate
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isDetectingFrame = false
            self.handleLiveDetection(detected, timestamp: now)
        }
    }

    private static func polygonArea(_ c: PageCorners) -> Double {
        let x1 = c.topLeft.x, y1 = c.topLeft.y
        let x2 = c.topRight.x, y2 = c.topRight.y
        let x3 = c.bottomRight.x, y3 = c.bottomRight.y
        let x4 = c.bottomLeft.x, y4 = c.bottomLeft.y
        return 0.5 * abs((x1 * y2 - y1 * x2) + (x2 * y3 - y2 * x3) + (x3 * y4 - y3 * x4) + (x4 * y1 - y4 * x1))
    }

    private func handleLiveDetection(_ incoming: PageCorners?, timestamp: CFTimeInterval) {
        guard !ended, !capturing, workflowMode != .qrCode else {
            hideLiveQuad()
            return
        }

        guard let incoming else {
            missedFrames += 1
            if missedFrames >= 4 {
                smoothedCorners = nil
                stabilityProgress = max(0, stabilityProgress - 0.25)
                autoRingProgress.strokeEnd = CGFloat(stabilityProgress)
                hideLiveQuad()
                updateGuidanceText()
            }
            return
        }

        missedFrames = 0
        let previous = smoothedCorners
        let smoothed: PageCorners
        if let prev = previous {
            let a = 0.45
            smoothed = PageCorners(
                topLeft: .init(CGPoint(x: prev.topLeft.x * (1 - a) + incoming.topLeft.x * a,
                                       y: prev.topLeft.y * (1 - a) + incoming.topLeft.y * a)),
                topRight: .init(CGPoint(x: prev.topRight.x * (1 - a) + incoming.topRight.x * a,
                                        y: prev.topRight.y * (1 - a) + incoming.topRight.y * a)),
                bottomLeft: .init(CGPoint(x: prev.bottomLeft.x * (1 - a) + incoming.bottomLeft.x * a,
                                          y: prev.bottomLeft.y * (1 - a) + incoming.bottomLeft.y * a)),
                bottomRight: .init(CGPoint(x: prev.bottomRight.x * (1 - a) + incoming.bottomRight.x * a,
                                           y: prev.bottomRight.y * (1 - a) + incoming.bottomRight.y * a))
            )
        } else {
            smoothed = incoming
        }
        smoothedCorners = smoothed
        drawLiveQuad(smoothed)

        guard autoCaptureEnabled, timestamp >= cooldownUntil else {
            autoRingProgress.strokeEnd = 0
            guidanceLabel.text = "Página detectada • Toque para capturar"
            return
        }

        if let prev = previous {
            let delta = max(
                hypot(smoothed.topLeft.x - prev.topLeft.x, smoothed.topLeft.y - prev.topLeft.y),
                hypot(smoothed.topRight.x - prev.topRight.x, smoothed.topRight.y - prev.topRight.y),
                hypot(smoothed.bottomLeft.x - prev.bottomLeft.x, smoothed.bottomLeft.y - prev.bottomLeft.y),
                hypot(smoothed.bottomRight.x - prev.bottomRight.x, smoothed.bottomRight.y - prev.bottomRight.y)
            )
            if delta < 0.032 {
                stabilityProgress = min(1.0, stabilityProgress + 0.14)
                guidanceLabel.text = "Não mexa • Captura automática (\(Int(stabilityProgress * 100))%)"
            } else {
                stabilityProgress = max(0.1, stabilityProgress - 0.12)
                guidanceLabel.text = "Mantenha o iPhone firme sobre a página"
            }
        } else {
            stabilityProgress = 0.15
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        autoRingProgress.strokeEnd = CGFloat(stabilityProgress)
        CATransaction.commit()

        if stabilityProgress >= 1.0 {
            stabilityProgress = 0
            autoRingProgress.strokeEnd = 0
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            lockedCaptureCorners = smoothed
            takePhoto()
        }
    }

    private func drawLiveQuad(_ corners: PageCorners) {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        func toViewPoint(_ unit: UnitPointRecord) -> CGPoint {
            // Vision origin is bottom-left; UIKit view origin is top-left.
            CGPoint(x: CGFloat(unit.x) * bounds.width, y: CGFloat(1.0 - unit.y) * bounds.height)
        }
        let pts = [
            toViewPoint(corners.topLeft),
            toViewPoint(corners.topRight),
            toViewPoint(corners.bottomRight),
            toViewPoint(corners.bottomLeft)
        ]
        let path = UIBezierPath()
        path.move(to: pts[0])
        path.addLine(to: pts[1])
        path.addLine(to: pts[2])
        path.addLine(to: pts[3])
        path.close()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        quadLayer.path = path.cgPath
        quadLayer.isHidden = false
        for (idx, pt) in pts.enumerated() where idx < cornerDots.count {
            cornerDots[idx].position = pt
            cornerDots[idx].isHidden = false
        }
        CATransaction.commit()
    }

    private func hideLiveQuad() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        quadLayer.isHidden = true
        for dot in cornerDots { dot.isHidden = true }
        autoRingProgress.strokeEnd = 0
        CATransaction.commit()
    }

    // MARK: - Capture & Processing

    @objc private func manualShutterTapped() {
        lockedCaptureCorners = smoothedCorners
        takePhoto()
    }

    @objc private func takePhoto() {
        guard !ended, !capturing, workflowMode != .qrCode, capturedPages.count < 50 else { return }
        capturing = true
        shutter.isEnabled = false
        finish.isEnabled = false
        let useFlash = flashOn
        captureQueue.async { [weak self] in
            guard let self else { return }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.photoQualityPrioritization = .quality
            if self.photoOutput.supportedFlashModes.contains(.on) {
                settings.flashMode = useFlash ? .on : .off
            }
            if let connection = self.photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let rawData = photo.fileDataRepresentation()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.ended else { return }
            self.capturing = false
            self.shutter.isEnabled = true
            self.cooldownUntil = CACurrentMediaTime() + 1.35

            if let error {
                self.guidanceLabel.text = error.localizedDescription
                self.finish.isEnabled = !self.capturedPages.isEmpty
                return
            }
            guard let rawData, let capturedImage = UIImage(data: rawData) else {
                self.guidanceLabel.text = "Captura sem imagem. Tente novamente."
                self.finish.isEnabled = !self.capturedPages.isEmpty
                return
            }

            let corners = self.lockedCaptureCorners ?? self.smoothedCorners
            self.lockedCaptureCorners = nil

            // ID Card 2-step Front + Back composite flow
            if self.workflowMode == .idCard && !self.singleOnly {
                if self.idCardFrontImage == nil {
                    self.idCardFrontImage = Self.croppedIDCardImage(capturedImage, corners: corners)
                    self.idGuideLabel.text = "Verso do Documento (2/2)"
                    self.guidanceLabel.text = "Frente capturada! Agora posicione o VERSO do documento"
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    return
                } else if let front = self.idCardFrontImage {
                    let back = Self.croppedIDCardImage(capturedImage, corners: corners)
                    self.idCardFrontImage = nil
                    self.idGuideLabel.text = "Frente do Documento (1/2)"
                    if let compositeData = Self.composeIDCardSheet(front: front, back: back) {
                        self.appendCapturedPage(CapturedScanPage(data: compositeData, corners: nil, filter: self.selectedFilter, autoCrop: false))
                        return
                    }
                }
            }

            // Timestamp mode bakes date/time stamp onto image before saving
            let finalData: Data
            if self.workflowMode == .timestamp, let stamped = Self.applyTimestampStamp(to: capturedImage) {
                finalData = stamped
            } else {
                finalData = rawData
            }

            self.appendCapturedPage(CapturedScanPage(data: finalData, corners: corners, filter: self.selectedFilter, autoCrop: true))
        }
    }

    private func appendCapturedPage(_ page: CapturedScanPage) {
        capturedPages.append(page)
        finish.setTitle("Concluir (\(capturedPages.count))", for: .normal)
        finish.isEnabled = true
        guidanceLabel.text = "\(capturedPages.count) página(s) digitalizada(s)"
        if !batchMode || singleOnly {
            finishCapture()
        } else if capturedPages.count >= 50 {
            shutter.isEnabled = false
            guidanceLabel.text = "Limite de 50 páginas atingido. Toque em Concluir."
        }
    }

    private static func croppedIDCardImage(_ source: UIImage, corners: PageCorners?) -> UIImage {
        let norm = ScanEngine.normalized(source, maximum: 1800)
        var page = ScanPage(id: UUID(), sourceFile: "id.source", renderedFile: "id.jpg", thumbnailFile: "id-t.jpg",
                            filter: .natural, autoCrop: true, corners: corners)
        if let processed = try? ScanEngine.processBase(norm, page: &page) {
            return processed
        }
        return norm
    }

    private static func composeIDCardSheet(front: UIImage, back: UIImage) -> Data? {
        let pageSize = CGSize(width: 1240, height: 1754) // A4 150dpi
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let sheet = UIGraphicsImageRenderer(size: pageSize, format: format).image { renderer in
            UIColor.white.setFill()
            renderer.fill(CGRect(origin: .zero, size: pageSize))
            let cardWidth: CGFloat = 780
            let cardHeight: CGFloat = 492
            let x = (pageSize.width - cardWidth) / 2
            let frontRect = CGRect(x: x, y: 260, width: cardWidth, height: cardHeight)
            let backRect = CGRect(x: x, y: 960, width: cardWidth, height: cardHeight)
            front.draw(in: ScanEngine.fit(front.size, inside: frontRect))
            back.draw(in: ScanEngine.fit(back.size, inside: backRect))
        }
        return sheet.jpegData(compressionQuality: 0.94)
    }

    private static func applyTimestampStamp(to image: UIImage) -> Data? {
        let norm = ScanEngine.normalized(image, maximum: ScanConfiguration.maximumWorkingDimension)
        let size = norm.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
        let stamp = "📅 \(formatter.string(from: Date()))\nCamScanner HD • Verificado no Dispositivo"
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            norm.draw(in: CGRect(origin: .zero, size: size))
            let fontSize = max(18, min(42, size.width * 0.026))
            let pad = fontSize * 0.7
            let boxWidth = min(size.width - 40, fontSize * 21)
            let boxHeight = fontSize * 3.1
            let box = CGRect(x: 28, y: size.height - boxHeight - 28, width: boxWidth, height: boxHeight)
            UIColor.black.withAlphaComponent(0.68).setFill()
            UIBezierPath(roundedRect: box, cornerRadius: 12).fill()
            (stamp as NSString).draw(in: box.insetBy(dx: pad, dy: pad * 0.6), withAttributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: UIColor.white
            ])
        }
        return rendered.jpegData(compressionQuality: ScanConfiguration.cameraJPEGQuality)
    }

    // MARK: - Native iOS VisionKit Document Camera Option

    @objc private func openSystemDocumentCamera() {
        guard VNDocumentCameraViewController.isSupported else {
            guidanceLabel.text = "Scanner nativo indisponível neste dispositivo."
            return
        }
        let vc = VNDocumentCameraViewController()
        vc.delegate = self
        present(vc, animated: true)
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
        controller.dismiss(animated: true) { [weak self] in
            guard let self, !self.ended else { return }
            for i in 0..<scan.pageCount {
                let img = scan.imageOfPage(at: i)
                if let jpeg = img.jpegData(compressionQuality: ScanConfiguration.cameraJPEGQuality) {
                    self.capturedPages.append(CapturedScanPage(data: jpeg, corners: nil, filter: self.selectedFilter, autoCrop: false))
                }
            }
            if !self.capturedPages.isEmpty {
                self.finishCapture()
            }
        }
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        controller.dismiss(animated: true)
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
        controller.dismiss(animated: true) { [weak self] in
            self?.guidanceLabel.text = error.localizedDescription
        }
    }

    // MARK: - Actions & Mode Switching

    @objc private func toggleAutoCapture() {
        autoCaptureEnabled.toggle()
        stabilityProgress = 0
        autoRingProgress.strokeEnd = 0
        autoButton.setTitle(autoCaptureEnabled ? " Auto: ON " : " Manual ", for: .normal)
        autoButton.backgroundColor = autoCaptureEnabled ? accentColor : UIColor.white.withAlphaComponent(0.2)
        updateGuidanceText()
    }

    @objc private func cycleFilterPreset() {
        let cycle: [PageFilter] = [.clean, .natural, .document, .removeShadow, .grayscale]
        let nextIndex = ((cycle.firstIndex(of: selectedFilter) ?? 0) + 1) % cycle.count
        selectedFilter = cycle[nextIndex]
        filterButton.setTitle(selectedFilter.title, for: .normal)
    }

    @objc private func changeBatchMode() {
        batchMode = batchToggle.selectedSegmentIndex == 1
        updateGuidanceText()
    }

    @objc private func selectWorkflowMode(_ sender: UIButton) {
        guard let chosen = CameraWorkflowMode(rawValue: sender.tag) else { return }
        workflowMode = chosen
        idCardFrontImage = nil
        updateWorkflowUI()
    }

    private func updateWorkflowUI() {
        for btn in modeButtons {
            let active = btn.tag == workflowMode.rawValue
            btn.titleLabel?.font = .systemFont(ofSize: 13, weight: active ? .bold : .medium)
            btn.setTitleColor(active ? accentColor : UIColor.white.withAlphaComponent(0.65), for: .normal)
        }
        let isQR = workflowMode == .qrCode
        shutterContainer.isHidden = isQR
        qrText.isHidden = !isQR
        copyQR.isHidden = !isQR
        idGuideBox.isHidden = workflowMode != .idCard
        timestampCard.isHidden = workflowMode != .timestamp
        if isQR { hideLiveQuad() }
        updateGuidanceText()
    }

    private func updateGuidanceText() {
        switch workflowMode {
        case .qrCode:
            guidanceLabel.text = "Aponte para um código QR para ler o conteúdo"
        case .idCard:
            guidanceLabel.text = idCardFrontImage == nil
                ? "Centralize a FRENTE do RG/CNH na moldura"
                : "Agora centralize o VERSO do RG/CNH na moldura"
        case .timestamp:
            guidanceLabel.text = "Carimbo de data/hora ativo • Enquadre a página"
        case .toExcel:
            guidanceLabel.text = "Enquadre a tabela ou planilha para converter em CSV"
        case .toWord:
            guidanceLabel.text = "Enquadre o documento para converter em Word (.doc)"
        case .ocr:
            guidanceLabel.text = "Enquadre o texto para reconhecimento óptico (OCR)"
        case .signature, .scan:
            guidanceLabel.text = autoCaptureEnabled
                ? "Coloque a página inteira na tela da câmera (Auto)"
                : "Coloque a página inteira na tela e toque para capturar"
        }
    }

    private func updateTimestampText() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
        timestampLabel.text = "📅 \(formatter.string(from: Date()))\n📍 CamScanner HD • Local\n✓ Verificado no iPhone"
    }

    @objc private func toggleFlash(_ sender: UIButton) {
        flashOn.toggle()
        sender.setImage(UIImage(systemName: flashOn ? "bolt.fill" : "bolt.slash.fill"), for: .normal)
        sender.tintColor = flashOn ? .systemYellow : .white
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !ended, workflowMode == .qrCode,
              let code = objects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first?.stringValue else { return }
        qrText.text = code
        guidanceLabel.text = "Código QR reconhecido"
    }

    @objc private func copyCode() {
        if !qrText.text.isEmpty {
            UIPasteboard.general.string = qrText.text
            guidanceLabel.text = "Código copiado para a área de transferência"
        }
    }

    @objc private func finishCapture() {
        guard !ended, !capturing, !capturedPages.isEmpty else { return }
        ended = true
        stop()
        if let onFinishPages {
            onFinishPages(capturedPages, workflowMode)
        } else {
            onFinish?(capturedPages.map(\.data))
        }
    }

    @objc private func cancelCapture() {
        guard !ended else { return }
        if capturedPages.isEmpty && idCardFrontImage == nil {
            ended = true
            stop()
            onCancel?()
            return
        }
        let alert = UIAlertController(
            title: "Descartar páginas capturadas?",
            message: "As páginas deste lote ainda não foram salvas.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Continuar", style: .cancel))
        alert.addAction(UIAlertAction(title: "Descartar", style: .destructive) { _ in
            self.ended = true
            self.stop()
            self.onCancel?()
        })
        present(alert, animated: true)
    }

    @objc private func interrupted() {
        DispatchQueue.main.async {
            self.shutter.isEnabled = false
            self.guidanceLabel.text = "Câmera em pausa. Retorne ao aplicativo."
        }
    }

    @objc private func resumed() {
        DispatchQueue.main.async {
            if !self.ended {
                self.shutter.isEnabled = !self.capturing
                self.updateGuidanceText()
            }
        }
    }

    @objc private func runtimeFailure(_ notification: Notification) {
        let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "A câmera foi interrompida."
        DispatchQueue.main.async {
            self.shutter.isEnabled = false
            self.guidanceLabel.text = message
        }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async {
            guard !self.ended else { return }
            self.ended = true
            self.stop()
            self.onError?(message)
        }
    }

    func stop() {
        timestampTimer?.invalidate()
        timestampTimer = nil
        captureQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    deinit {
        timestampTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}
