import SwiftUI
import UniformTypeIdentifiers

// MARK: - ファイル書き出し用
struct DataDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum ActiveSheet: Identifiable {
    case count(String)      // 商品のバーコード
    case unknown(String)    // 登録されていないバーコード
    case export
    case settings

    var id: String {
        switch self {
        case .count(let c): return "count-" + c
        case .unknown(let c): return "unknown-" + c
        case .export: return "export"
        case .settings: return "settings"
        }
    }
}

enum ListFilter: String, CaseIterable, Identifiable {
    case all = "すべて"
    case uncounted = "未チェック"
    case counted = "チェック済"
    case diff = "差異あり"
    var id: String { rawValue }
}

struct Toast: Equatable {
    let message: String
    let undoCode: String?
}

// MARK: - メイン画面
struct ContentView: View {
    @StateObject private var store = InventoryStore()
    @AppStorage("plusOneMode") private var plusOneMode = false
    @AppStorage("cameraZoom") private var zoom = 1.0
    @State private var torchOn = false
    @State private var sheet: ActiveSheet?
    @State private var filter: ListFilter = .all
    @State private var searchText = ""
    @State private var showImporter = false
    @State private var showManualInput = false
    @State private var manualCode = ""
    @State private var alertMessage: String?
    @State private var toast: Toast?
    @State private var confirmReset = false
    @State private var confirmDeleteAll = false

    private var countedCount: Int { store.items.filter { $0.count != nil }.count }

    private var filteredItems: [InventoryItem] {
        var list = store.items
        switch filter {
        case .all: break
        case .uncounted: list = list.filter { $0.count == nil }
        case .counted: list = list.filter { $0.count != nil }
        case .diff: list = list.filter { ($0.difference ?? 0) != 0 }
        }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter { Self.matches($0, q) }
        }
        return list
    }

    static func matches(_ item: InventoryItem, _ q: String) -> Bool {
        let fields = [item.name, item.hinban, item.code, item.ownCode] + (item.aliases ?? [])
        return fields.contains { $0.localizedStandardContains(q) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                scannerArea
                progressBar
                Picker("表示", selection: $filter) {
                    ForEach(ListFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 6)
                itemList
            }
            .navigationTitle("棚卸し")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(item: $sheet) { s in sheetView(s) }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    do {
                        let r = try store.importFile(url: url)
                        var msg = "新規 \(r.added)件、更新 \(r.updated)件を読み込みました。"
                        if r.skipped > 0 { msg += "\nコードが空の行 \(r.skipped)件は読み飛ばしました。" }
                        alertMessage = msg
                    } catch {
                        alertMessage = "読み込みに失敗しました：\(error.localizedDescription)"
                    }
                case .failure(let error):
                    alertMessage = "ファイルを開けませんでした：\(error.localizedDescription)"
                }
            }
            .alert("コードを手入力", isPresented: $showManualInput) {
                TextField("バーコードの数字・英字", text: $manualCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button("キャンセル", role: .cancel) {}
                Button("決定") {
                    let code = manualCode.trimmingCharacters(in: .whitespaces)
                    guard !code.isEmpty else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { handleScan(code) }
                }
            }
            .alert("お知らせ", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
            .confirmationDialog("すべての数をクリアして、棚卸しを最初からやり直しますか？", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("数をクリアする", role: .destructive) { store.resetCounts() }
            }
            .confirmationDialog("商品の一覧をすべて削除しますか？（ひも付けも消えます）", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("すべて削除する", role: .destructive) { store.deleteAll() }
            }
        }
    }

    // MARK: 部品
    private var scannerArea: some View {
        ZStack {
            BarcodeScannerView(onScanned: { handleScan($0) },
                               isPaused: sheet != nil || showManualInput || showImporter,
                               zoom: zoom, torchOn: torchOn)
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.green, lineWidth: 2)
                .frame(width: ScannerViewController.frameSize.width, height: ScannerViewController.frameSize.height)
            VStack {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        ForEach([1.0, 2.0, 3.0], id: \.self) { z in
                            Button {
                                zoom = z
                            } label: {
                                Text("\(Int(z))x")
                                    .font(.caption.bold())
                                    .frame(width: 38, height: 38)
                                    .background(zoom == z ? Color.yellow : Color.black.opacity(0.55))
                                    .foregroundColor(zoom == z ? .black : .white)
                                    .clipShape(Circle())
                            }
                        }
                        Button {
                            torchOn.toggle()
                        } label: {
                            Image(systemName: torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                                .font(.callout)
                                .frame(width: 38, height: 38)
                                .background(torchOn ? Color.yellow : Color.black.opacity(0.55))
                                .foregroundColor(torchOn ? .black : .white)
                                .clipShape(Circle())
                        }
                    }
                    .padding(.trailing, 8)
                }
                Spacer()
            }
            VStack {
                Spacer()
                Text(plusOneMode ? "読み取るたびに数量が1増えます" : "読み取るバーコードを枠の中央に合わせてください")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6))
                    .foregroundColor(.white)
                    .cornerRadius(6)
                    .padding(.bottom, 8)
            }
            if let toast {
                VStack {
                    HStack {
                        Text(toast.message)
                            .font(.subheadline.bold())
                            .lineLimit(2)
                        Spacer()
                        if let code = toast.undoCode {
                            Button("取り消す") { undoPlusOne(code) }
                                .font(.subheadline.bold())
                        }
                    }
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                    .padding(8)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(height: 230)
        .clipped()
    }

    private var progressBar: some View {
        let total = store.items.count
        return VStack(spacing: 4) {
            HStack {
                Text("チェック済み \(countedCount) / \(total)")
                    .font(.subheadline.bold())
                Spacer()
                if total > 0 {
                    Text("残り \(total - countedCount)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            ProgressView(value: total == 0 ? 0 : Double(countedCount), total: Double(max(total, 1)))
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var itemList: some View {
        List {
            if store.items.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("商品が登録されていません")
                            .font(.headline)
                        Text("右上のメニューの「商品一覧を読み込み」から、在庫スイートから出力したExcel（xlsx）またはCSVファイルを読み込んでください。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
            ForEach(filteredItems) { item in
                Button {
                    sheet = .count(item.code)
                } label: {
                    ItemRow(item: item)
                }
            }
            .onDelete { offsets in
                let codes = offsets.map { filteredItems[$0].code }
                store.delete(codes: codes)
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "品名・品番・コードで検索")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                manualCode = ""
                showManualInput = true
            } label: {
                Image(systemName: "keyboard")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { showImporter = true } label: {
                    Label("商品一覧を読み込み", systemImage: "square.and.arrow.down")
                }
                Button { sheet = .export } label: {
                    Label("棚卸し結果を書き出し", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button { sheet = .settings } label: {
                    Label("設定", systemImage: "gearshape")
                }
                Divider()
                Button(role: .destructive) { confirmReset = true } label: {
                    Label("棚卸しをやり直す（数をクリア）", systemImage: "arrow.counterclockwise")
                }
                Button(role: .destructive) { confirmDeleteAll = true } label: {
                    Label("商品一覧をすべて削除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private func sheetView(_ s: ActiveSheet) -> some View {
        switch s {
        case .count(let code):
            CountSheet(store: store, code: code)
        case .unknown(let code):
            UnknownCodeSheet(store: store, scannedCode: code) { linkedCode in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if plusOneMode, let item = store.increment(linkedCode) {
                        showToast(item)
                    } else {
                        sheet = .count(linkedCode)
                    }
                }
            }
        case .export:
            ExportSheet(store: store)
        case .settings:
            SettingsSheet(plusOneMode: $plusOneMode)
        }
    }

    // MARK: 動作
    private func handleScan(_ code: String) {
        guard let item = store.find(code) else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            sheet = .unknown(code)
            return
        }
        if plusOneMode {
            if let updated = store.increment(code) { showToast(updated) }
        } else {
            sheet = .count(item.code)
        }
    }

    private func showToast(_ item: InventoryItem) {
        let t = Toast(message: "\(item.displayName) \(item.hinban)  → \(item.count ?? 0)", undoCode: item.code)
        withAnimation { toast = t }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if toast == t { withAnimation { toast = nil } }
        }
    }

    private func undoPlusOne(_ code: String) {
        if let item = store.find(code), let c = item.count {
            store.setCount(code: code, count: c <= 1 ? nil : c - 1)
        }
        withAnimation { toast = nil }
    }
}

// MARK: - 一覧の行
struct ItemRow: View {
    let item: InventoryItem

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: item.count == nil ? "circle" : "checkmark.circle.fill")
                .foregroundColor(item.count == nil ? .secondary : .green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.subheadline.bold())
                    .foregroundColor(.primary)
                    .lineLimit(2)
                if !item.hinban.isEmpty {
                    Text(item.hinban)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
                Text(item.code)
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let c = item.count {
                    Text("\(c)\(item.unit)")
                        .font(.headline.monospacedDigit())
                        .foregroundColor(.primary)
                } else {
                    Text("未")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                if let b = item.bookQty {
                    Text("帳簿 \(b)")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                if let d = item.difference, d != 0 {
                    Text(d > 0 ? "+\(d)" : "\(d)")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundColor(.red)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 数の入力
struct CountSheet: View {
    @ObservedObject var store: InventoryStore
    let code: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var name = ""
    @State private var hinban = ""
    @State private var loaded = false
    @FocusState private var focused: Bool

    private var item: InventoryItem? { store.find(code) }
    private var number: Int? { Int(text.filter { $0.isNumber }) }

    var body: some View {
        NavigationStack {
            Form {
                if let item {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.displayName).font(.headline)
                            if !item.hinban.isEmpty { Text(item.hinban).font(.subheadline) }
                            Text(item.code).font(.caption.monospaced()).foregroundColor(.secondary)
                            if !item.ownCode.isEmpty && item.ownCode != item.code {
                                Text("自社コード \(item.ownCode)").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    Section("数えた数") {
                        HStack {
                            TextField("0", text: $text)
                                .keyboardType(.numberPad)
                                .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                                .focused($focused)
                            Text(item.unit).font(.title3)
                        }
                        HStack(spacing: 12) {
                            ForEach([-1, 1, 5, 10], id: \.self) { step in
                                Button(step > 0 ? "+\(step)" : "\(step)") {
                                    text = String(max(0, (number ?? 0) + step))
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        if let b = item.bookQty {
                            HStack {
                                Text("帳簿の数")
                                Spacer()
                                Text("\(b)\(item.unit)").monospacedDigit()
                            }
                            if let n = number {
                                HStack {
                                    Text("差")
                                    Spacer()
                                    Text(n - b > 0 ? "+\(n - b)" : "\(n - b)")
                                        .monospacedDigit()
                                        .foregroundColor(n == b ? .green : .red)
                                        .bold()
                                }
                            }
                        }
                    }
                    if !(item.aliases ?? []).isEmpty {
                        Section("ひも付けたバーコード") {
                            ForEach(item.aliases ?? [], id: \.self) { a in
                                Text(a).font(.body.monospaced())
                            }
                            .onDelete { offsets in
                                let list = item.aliases ?? []
                                for i in offsets { store.unlink(alias: list[i], from: item.code) }
                            }
                        }
                    }
                    if item.count != nil {
                        Section {
                            Button("未チェックに戻す", role: .destructive) {
                                store.setCount(code: item.code, count: nil)
                                dismiss()
                            }
                        }
                    }
                } else {
                    Text("商品が見つかりません")
                }
            }
            .navigationTitle("数の入力")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.setCount(code: code, count: number ?? 0)
                        dismiss()
                    }
                    .bold()
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let c = item?.count { text = String(c) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true }
            }
        }
    }
}

// MARK: - 登録されていないコード
struct UnknownCodeSheet: View {
    @ObservedObject var store: InventoryStore
    let scannedCode: String
    var onLinked: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var showNew = false
    @State private var newName = ""
    @State private var newHinban = ""
    @State private var newUnit = ""

    private var candidates: [InventoryItem] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return Array(store.items.filter { ContentView.matches($0, q) }.prefix(50))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("登録されていないバーコードです")
                            .font(.headline)
                        Text(scannedCode)
                            .font(.title3.monospaced())
                        Text("どの商品のバーコードか、品名や品番で検索して選んでください。選んだ商品にこのバーコードをひも付けて、次回から読み取れるようにします。在庫スイートの登録コードは変わりません。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                Section("候補") {
                    if search.isEmpty {
                        Text("上の検索欄に品名や品番を入力してください")
                            .foregroundColor(.secondary)
                    } else if candidates.isEmpty {
                        Text("見つかりませんでした")
                            .foregroundColor(.secondary)
                    }
                    ForEach(candidates) { item in
                        Button {
                            store.link(alias: scannedCode, to: item.code)
                            dismiss()
                            onLinked(item.code)
                        } label: {
                            ItemRow(item: item)
                        }
                    }
                }
                Section {
                    Button("一覧に無い商品として追加する") { showNew = true }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "品名・品番で検索")
            .navigationTitle("ひも付け")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
            .alert("新しい商品を追加", isPresented: $showNew) {
                TextField("品名", text: $newName)
                TextField("品番（任意）", text: $newHinban)
                TextField("単位（任意）", text: $newUnit)
                Button("キャンセル", role: .cancel) {}
                Button("追加") {
                    let item = InventoryItem(code: scannedCode, ownCode: "", name: newName, hinban: newHinban,
                                             unit: newUnit, bookQty: nil, count: nil, countedAt: nil, aliases: nil)
                    store.upsert(item)
                    dismiss()
                    onLinked(scannedCode)
                }
            } message: {
                Text("この商品はアプリの中だけに追加されます。在庫スイートには登録されません。")
            }
        }
    }
}

// MARK: - 書き出し
struct ExportSheet: View {
    @ObservedObject var store: InventoryStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("exportIncludeUncounted") private var includeUncounted = false
    @AppStorage("exportEncoding") private var encodingRaw = ExportEncoding.shiftJIS.rawValue
    @State private var document: DataDocument?
    @State private var showExporter = false
    @State private var errorMessage: String?

    private var fileName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmm"
        return "棚卸し_\(f.string(from: Date()))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("未チェックの商品も含める（数は0）", isOn: $includeUncounted)
                    Picker("文字コード", selection: $encodingRaw) {
                        ForEach(ExportEncoding.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                } footer: {
                    Text("在庫スイートに取り込んで文字化けする場合は、文字コードを切り替えてください。バーコード欄は在庫スイートの登録コードのまま出力します。")
                }
                Section {
                    Button {
                        let enc = ExportEncoding(rawValue: encodingRaw) ?? .shiftJIS
                        document = DataDocument(data: store.exportCSV(includeUncounted: includeUncounted, encoding: enc))
                        showExporter = true
                    } label: {
                        Label("CSVを書き出す", systemImage: "square.and.arrow.up")
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundColor(.red)
                }
            }
            .navigationTitle("棚卸し結果の書き出し")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .fileExporter(isPresented: $showExporter, document: document,
                          contentType: .commaSeparatedText, defaultFilename: fileName) { result in
                switch result {
                case .success: dismiss()
                case .failure(let e): errorMessage = "書き出しに失敗しました：\(e.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - 設定
struct SettingsSheet: View {
    @Binding var plusOneMode: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("読み取るたびに数量を1増やす", isOn: $plusOneMode)
                } footer: {
                    Text("オフ：棚のラベルを読み取ると、数を入力する画面が開きます。\nオン：商品のバーコードを1個ずつ読み取って数える時に使います。")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }
}
