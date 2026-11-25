import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - データモデル
struct ProductItem: Identifiable, Codable, Equatable {
    var id: String { jan }
    let jan: String
    var name: String
    var count: Int
    var updatedAt: Date
}

// MARK: - ストア（保存・CSV入出力）
@MainActor
class ProductStore: ObservableObject {
    @Published var items: [ProductItem] = []
    private let saveKey = "saved_jan_products_v1"

    init() {
        load()
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: saveKey),
              let decoded = try? JSONDecoder().decode([ProductItem].self, from: data) else { return }
        items = decoded
    }

    func save() {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: saveKey)
        }
    }

    func upsert(jan: String, name: String, count: Int) {
        if let idx = items.firstIndex(where: { $0.jan == jan }) {
            items[idx].name = name
            items[idx].count = max(0, count)
            items[idx].updatedAt = Date()
            let updated = items.remove(at: idx)
            items.insert(updated, at: 0)
        } else {
            let newItem = ProductItem(jan: jan, name: name, count: max(0, count), updatedAt: Date())
            items.insert(newItem, at: 0)
        }
        save()
    }

    func delete(ids: [String]) {
        items.removeAll { ids.contains($0.jan) }
        save()
    }

    /// JAN-13 / JAN-8 のチェックデジット確認
    static func isValidJAN(_ code: String) -> Bool {
        guard code.count == 13 || code.count == 8,
              code.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        let digits = code.compactMap { Int(String($0)) }
        let body = digits.dropLast()
        var sum = 0
        for (i, d) in body.reversed().enumerated() {
            sum += (i % 2 == 0) ? d * 3 : d
        }
        return (10 - sum % 10) % 10 == digits.last
    }

    func exportCSV() -> String {
        let bom = "\u{FEFF}"
        var lines = ["JANコード,商品名,数量,更新日時"]
        let formatter = ISO8601DateFormatter()
        for item in items {
            let escapedName = item.name.replacingOccurrences(of: "\"", with: "\"\"")
            lines.append("\"\(item.jan)\",\"\(escapedName)\",\(item.count),\(formatter.string(from: item.updatedAt))")
        }
        return bom + lines.joined(separator: "\n")
    }

    func importCSV(from url: URL) throws -> Int {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        guard let decoded = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .shiftJIS) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let raw = decoded.replacingOccurrences(of: "\u{FEFF}", with: "")
        let rows = raw.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        var importedCount = 0
        for (index, row) in rows.enumerated() {
            let cols = parseCSVRow(row)
            guard cols.count >= 2 else { continue }
            let jan = cols[0].trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "\"", with: "")
            let name = cols[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if index == 0 && (jan.contains("JAN") || jan.contains("jan") || jan.contains("コード")) {
                continue
            }
            guard !jan.isEmpty else { continue }
            let count = cols.count >= 3 ? (Int(cols[2].trimmingCharacters(in: .whitespaces)) ?? 1) : 1

            if let idx = items.firstIndex(where: { $0.jan == jan }) {
                items[idx].name = name
                items[idx].count = count
                items[idx].updatedAt = Date()
            } else {
                items.append(ProductItem(jan: jan, name: name, count: count, updatedAt: Date()))
            }
            importedCount += 1
        }
        save()
        return importedCount
    }

    private func parseCSVRow(_ row: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(row)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if inQuotes && i + 1 < chars.count && chars[i + 1] == "\"" {
                    current.append("\"")
                    i += 1
                } else {
                    inQuotes.toggle()
                }
            } else if c == "," && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        result.append(current)
        return result
    }
}

// MARK: - CSVドキュメント
struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let str = String(data: data, encoding: .utf8) {
            text = str
        } else {
            text = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - バーコードスキャナー
struct BarcodeScannerView: UIViewControllerRepresentable {
    var onScanned: (String) -> Void
    @Binding var isPaused: Bool

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onScanned = onScanned
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {
        uiViewController.setPaused(isPaused)
    }
}

class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScanned: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isPaused = false
    private var lastCode: String?
    private var lastScanTime: Date = .distantPast

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

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            output.metadataObjectTypes = [.ean13, .ean8]
        }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        self.previewLayer = preview

        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        updatePreviewRotation()
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
        self.isPaused = paused
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !isPaused,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let code = obj.stringValue,
              ProductStore.isValidJAN(code) else { return }

        let now = Date()
        if code == lastCode && now.timeIntervalSince(lastScanTime) < 2.0 {
            return
        }
        lastCode = code
        lastScanTime = now

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        onScanned?(code)
    }
}

// MARK: - メイン画面
struct ContentView: View {
    @StateObject private var store = ProductStore()
    @State private var scannedJAN: String?
    @State private var inputName: String = ""
    @State private var inputCount: Int = 1
    @State private var isNewScan = true
    @State private var showManualInput = false
    @State private var manualJAN = ""
    @State private var showInputSheet = false
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var alertMessage: String?
    @State private var searchText = ""

    var filteredItems: [ProductItem] {
        if searchText.isEmpty { return store.items }
        return store.items.filter {
            $0.jan.contains(searchText) || $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    BarcodeScannerView(onScanned: { code in
                        handleScan(code)
                    }, isPaused: Binding(get: { showInputSheet || showManualInput || showImporter || showExporter }, set: { _ in }))
                    .frame(height: 240)
                    .clipped()

                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.green, lineWidth: 2)
                        .frame(width: 260, height: 110)

                    VStack {
                        Spacer()
                        Text("JANコード（13桁 / 8桁）を枠内に合わせてください")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.6))
                            .foregroundColor(.white)
                            .cornerRadius(6)
                            .padding(.bottom, 8)
                    }
                }
                .frame(height: 240)

                List {
                    ForEach(filteredItems) { item in
                        Button {
                            scannedJAN = item.jan
                            inputName = item.name
                            inputCount = item.count
                            isNewScan = false
                            showInputSheet = true
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name.isEmpty ? "（名称未設定）" : item.name)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text("JAN: \(item.jan)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text("×\(item.count)")
                                    .font(.subheadline.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.blue.opacity(0.12))
                                    .foregroundColor(.blue)
                                    .cornerRadius(6)
                            }
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { filteredItems[$0].jan }
                        store.delete(ids: ids)
                    }
                }
                .searchable(text: $searchText, prompt: "JANまたは商品名で検索")
            }
            .navigationTitle("JANスキャナー (\(store.items.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        manualJAN = ""
                        showManualInput = true
                    } label: {
                        Image(systemName: "keyboard")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showExporter = true
                        } label: {
                            Label("CSVを書き出し", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            showImporter = true
                        } label: {
                            Label("CSVを読み込み", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "doc.text")
                    }
                }
            }
            .sheet(isPresented: $showInputSheet) {
                NavigationStack {
                    Form {
                        Section("読み取りコード") {
                            Text(scannedJAN ?? "")
                                .font(.title3.monospaced())
                        }
                        Section("商品名") {
                            TextField("商品名を入力", text: $inputName)
                                .submitLabel(.done)
                                .onSubmit { saveCurrent() }
                        }
                        Section(isNewScan ? "数量（読み取りで+1されます）" : "数量") {
                            Stepper(value: $inputCount, in: 0...99999) {
                                Text("\(inputCount)")
                                    .font(.title3.monospacedDigit())
                            }
                        }
                    }
                    .navigationTitle("商品登録")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("キャンセル") { showInputSheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") { saveCurrent() }
                                .disabled(inputName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .alert("JANコードを手入力", isPresented: $showManualInput) {
                TextField("13桁または8桁", text: $manualJAN)
                    .keyboardType(.numberPad)
                Button("キャンセル", role: .cancel) {}
                Button("決定") {
                    let code = manualJAN.filter { $0.isNumber }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        if ProductStore.isValidJAN(code) {
                            handleScan(code)
                        } else {
                            alertMessage = "JANコードが正しくありません（桁数またはチェックデジットを確認してください）"
                        }
                    }
                }
            }
            .fileExporter(
                isPresented: $showExporter,
                document: CSVDocument(text: store.exportCSV()),
                contentType: .commaSeparatedText,
                defaultFilename: "jan_list_\(Int(Date().timeIntervalSince1970))"
            ) { result in
                if case .failure(let error) = result {
                    alertMessage = "書き出し失敗: \(error.localizedDescription)"
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.commaSeparatedText, .plainText],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    do {
                        let count = try store.importCSV(from: url)
                        alertMessage = "\(count)件のデータを読み込みました"
                    } catch {
                        alertMessage = "読み込み失敗: \(error.localizedDescription)"
                    }
                case .failure(let error):
                    alertMessage = "選択エラー: \(error.localizedDescription)"
                }
            }
            .alert("通知", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    private func handleScan(_ code: String) {
        scannedJAN = code
        isNewScan = true
        if let existing = store.items.first(where: { $0.jan == code }) {
            inputName = existing.name
            inputCount = existing.count + 1
        } else {
            inputName = ""
            inputCount = 1
        }
        showInputSheet = true
    }

    private func saveCurrent() {
        guard let jan = scannedJAN else { return }
        store.upsert(jan: jan, name: inputName.trimmingCharacters(in: .whitespaces), count: inputCount)
        showInputSheet = false
    }
}

@main
struct JanScannerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
