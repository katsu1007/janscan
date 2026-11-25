import SwiftUI
import AVFoundation

struct BarcodeScannerView: UIViewControllerRepresentable {
    var onScanned: (String) -> Void
    var isPaused: Bool

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onScanned = onScanned
        return vc
    }

    func updateUIViewController(_ vc: ScannerViewController, context: Context) {
        vc.onScanned = onScanned
        vc.setPaused(isPaused)
    }
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScanned: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var metadataOutput: AVCaptureMetadataOutput?
    /// 画面の緑の枠と同じ大きさ（この範囲だけ読み取る）
    static let frameSize = CGSize(width: 280, height: 80)

    private var scanRect: CGRect {
        let w = min(Self.frameSize.width, view.bounds.width)
        let h = min(Self.frameSize.height, view.bounds.height)
        return CGRect(x: view.bounds.midX - w / 2, y: view.bounds.midY - h / 2, width: w, height: h)
    }
    private var isPaused = false
    private var lastCode: String?
    private var lastSeen: Date = .distantPast

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.setupCamera() } else { self.showMessage("カメラが許可されていません。\n設定アプリからカメラを許可してください。") }
                }
            }
        default:
            showMessage("カメラが許可されていません。\n設定アプリからカメラを許可してください。")
        }
    }

    private func showMessage(_ text: String) {
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .footnote)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16)
        ])
    }

    private func setupCamera() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            showMessage("カメラを起動できませんでした。")
            return
        }
        session.addInput(input)
        if device.isAutoFocusRangeRestrictionSupported, (try? device.lockForConfiguration()) != nil {
            device.autoFocusRangeRestriction = .near
            device.unlockForConfiguration()
        }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            // 棚ラベル（Code128など）と商品のJANの両方を読む
            let wanted: [AVMetadataObject.ObjectType] = [
                .code128, .ean13, .ean8, .upce, .code39, .code39Mod43, .code93,
                .itf14, .interleaved2of5, .qr, .dataMatrix
            ]
            output.metadataObjectTypes = wanted.filter { output.availableMetadataObjectTypes.contains($0) }
            metadataOutput = output
        }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        previewLayer = preview

        let s = session
        DispatchQueue.global(qos: .userInitiated).async {
            s.startRunning()
            DispatchQueue.main.async { self.updateRectOfInterest() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        updatePreviewRotation()
        updateRectOfInterest()
    }

    private func updateRectOfInterest() {
        guard let layer = previewLayer, let output = metadataOutput, session.isRunning else { return }
        // 枠より少しだけ広く取る（端のバーコードが欠けないように）
        let r = scanRect.insetBy(dx: -10, dy: -10)
        output.rectOfInterest = layer.metadataOutputRectConverted(fromLayerRect: r)
    }

    private func updatePreviewRotation() {
        guard let connection = previewLayer?.connection else { return }
        let angle: CGFloat
        switch view.window?.windowScene?.interfaceOrientation ?? .portrait {
        case .landscapeLeft: angle = 180
        case .landscapeRight: angle = 0
        case .portraitUpsideDown: angle = 270
        default: angle = 90
        }
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    func setPaused(_ paused: Bool) {
        if isPaused && !paused {
            // 画面を閉じた直後に同じラベルを読み直さないように
            lastSeen = Date()
        }
        isPaused = paused
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        // 複数のバーコードが映った時は、枠の中心に一番近いものを選ぶ
        let center = CGPoint(x: scanRect.midX, y: scanRect.midY)
        var best: (code: String, dist: CGFloat)?
        for o in metadataObjects {
            guard let c = o as? AVMetadataMachineReadableCodeObject, let v = c.stringValue else { continue }
            let rect = previewLayer?.transformedMetadataObject(for: c)?.bounds ?? .zero
            // 中心が枠の外にあるものは無視
            if previewLayer != nil && !scanRect.contains(CGPoint(x: rect.midX, y: rect.midY)) { continue }
            let d = hypot(rect.midX - center.x, rect.midY - center.y)
            if best == nil || d < best!.dist { best = (v, d) }
        }
        guard let raw = best?.code else { return }
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        let now = Date()
        // 同じコードは一度カメラから外れる（1秒以上見えなくなる）までは読まない
        if code == lastCode && now.timeIntervalSince(lastSeen) < 1.0 {
            lastSeen = now
            return
        }
        guard !isPaused else { return }
        lastCode = code
        lastSeen = now
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onScanned?(code)
    }
}
