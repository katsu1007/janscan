import SwiftUI
import AVFoundation
import Vision

struct BarcodeScannerView: UIViewControllerRepresentable {
    var onScanned: (String) -> Void
    var isPaused: Bool
    var zoom: Double
    var torchOn: Bool

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onScanned = onScanned
        return vc
    }

    func updateUIViewController(_ vc: ScannerViewController, context: Context) {
        vc.onScanned = onScanned
        vc.setPaused(isPaused)
        vc.setZoom(zoom)
        vc.setTorch(torchOn)
    }
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onScanned: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var metadataOutput: AVCaptureMetadataOutput?
    /// 画面の緑の枠と同じ大きさ（この範囲だけ読み取る）
    static let frameSize = CGSize(width: 280, height: 80)
    private var device: AVCaptureDevice?
    private var baseZoom: CGFloat = 1     // 「1x」（普通の広角カメラ）にあたる倍率
    private var requestedZoom: Double = 1
    private var requestedTorch = false

    // Vision（角度・傾きに強い読み取り）
    private let videoQueue = DispatchQueue(label: "janscanner.vision")
    private let roiLock = NSLock()
    private var visionROI = CGRect(x: 0, y: 0, width: 1, height: 1)   // センサー座標・左下原点
    private var visionBusy = false

    /// 実際に読み取る範囲（枠より上下に広い）
    private var readRect: CGRect {
        scanRect.insetBy(dx: -20, dy: -50).intersection(view.bounds)
    }

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
        // 近くにピントが合いやすいよう、超広角へ自動で切り替わるカメラを優先
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera],
            mediaType: .video, position: .back)
        guard let device = discovery.devices.first ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            showMessage("カメラを起動できませんでした。")
            return
        }
        session.addInput(input)
        self.device = device
        if let first = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            baseZoom = CGFloat(truncating: first)
        }
        if (try? device.lockForConfiguration()) != nil {
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .near
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
        }
        applyZoom()

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            // 棚ラベル（Code128など）と商品のJANの両方を読む
            let wanted: [AVMetadataObject.ObjectType] = [
                .code128, .ean13, .ean8, .upce, .code39, .code39Mod43, .code93,
                .itf14, .qr, .dataMatrix
            ]
            output.metadataObjectTypes = wanted.filter { output.availableMetadataObjectTypes.contains($0) }
            metadataOutput = output
        }

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        previewLayer = preview

        let s = session
        DispatchQueue.global(qos: .userInitiated).async {
            s.startRunning()
            DispatchQueue.main.async {
                self.updateRectOfInterest()
                self.applyTorch()
            }
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
        // 角度が付いて斜めに映っても読めるよう、上下を広めに取る
        let r = readRect
        let m = layer.metadataOutputRectConverted(fromLayerRect: r)
        output.rectOfInterest = m
        // Visionは左下原点なので上下を反転
        var roi = CGRect(x: m.minX, y: 1 - m.maxY, width: m.width, height: m.height)
        roi = roi.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        roiLock.lock()
        visionROI = roi.isNull || roi.isEmpty ? CGRect(x: 0, y: 0, width: 1, height: 1) : roi
        roiLock.unlock()
    }

    // MARK: Vision
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        roiLock.lock()
        if visionBusy { roiLock.unlock(); return }
        visionBusy = true
        let roi = visionROI
        roiLock.unlock()
        defer {
            roiLock.lock(); visionBusy = false; roiLock.unlock()
        }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.code128, .ean13, .ean8, .upce, .code39, .code39Checksum,
                               .code39FullASCII, .code93, .itf14, .qr, .dataMatrix]
        request.regionOfInterest = roi
        // 向きは指定しない（センサーの向きのまま）。座標をプレビューに合わせて変換する
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil,
              let results = request.results, !results.isEmpty else { return }

        var found: [(String, CGRect)] = []
        for obs in results {
            guard let v = obs.payloadStringValue, !v.isEmpty else { continue }
            // boundingBox は regionOfInterest 内の正規化座標 → 画像全体の座標へ
            let b = obs.boundingBox
            let full = CGRect(x: roi.minX + b.minX * roi.width,
                              y: roi.minY + b.minY * roi.height,
                              width: b.width * roi.width,
                              height: b.height * roi.height)
            // 左下原点 → 左上原点（メタデータ座標）
            let meta = CGRect(x: full.minX, y: 1 - full.maxY, width: full.width, height: full.height)
            found.append((v, meta))
        }
        guard !found.isEmpty else { return }
        DispatchQueue.main.async {
            guard let layer = self.previewLayer else { return }
            let converted = found.map { ($0.0, layer.layerRectConverted(fromMetadataOutputRect: $0.1)) }
            self.handleCandidates(converted)
        }
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

    func setZoom(_ z: Double) {
        guard z != requestedZoom else { return }
        requestedZoom = z
        applyZoom()
    }

    func setTorch(_ on: Bool) {
        guard on != requestedTorch else { return }
        requestedTorch = on
        applyTorch()
    }

    private func applyZoom() {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        let target = baseZoom * CGFloat(requestedZoom)
        let clamped = min(max(target, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        device.ramp(toVideoZoomFactor: clamped, withRate: 8)
        device.unlockForConfiguration()
    }

    private func applyTorch() {
        guard let device, device.hasTorch, session.isRunning,
              (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = requestedTorch ? .on : .off
        device.unlockForConfiguration()
    }

    func setPaused(_ paused: Bool) {
        if isPaused && !paused {
            // 画面を閉じた直後に同じラベルを読み直さないように
            lastSeen = Date()
        }
        isPaused = paused
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        var list: [(String, CGRect)] = []
        for o in metadataObjects {
            guard let c = o as? AVMetadataMachineReadableCodeObject, let v = c.stringValue,
                  let rect = previewLayer?.transformedMetadataObject(for: c)?.bounds else { continue }
            list.append((v, rect))
        }
        handleCandidates(list)
    }

    /// 見つかったバーコード（画面上の位置つき）から、枠の中心に一番近いものを採用
    private func handleCandidates(_ list: [(String, CGRect)]) {
        let center = CGPoint(x: scanRect.midX, y: scanRect.midY)
        var best: (code: String, dist: CGFloat)?
        for (v, rect) in list {
            // 中心が読み取り範囲の外にあるものは無視
            if !readRect.contains(CGPoint(x: rect.midX, y: rect.midY)) { continue }
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
