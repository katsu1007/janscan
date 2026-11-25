import Foundation

struct InventoryItem: Identifiable, Codable, Equatable {
    var id: String { code }
    var code: String          // バーコード
    var ownCode: String       // 自社コード
    var name: String          // 品名
    var hinban: String        // 品番
    var unit: String          // 単位
    var bookQty: Int?         // 帳簿数（現品数）
    var count: Int?           // 実数（nil = 未カウント）
    var countedAt: Date?
    var aliases: [String]?    // ひも付けた別のバーコード（アプリ内だけ）

    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "（品名未設定）" : n
    }
    var difference: Int? {
        guard let c = count, let b = bookQty else { return nil }
        return c - b
    }
}

enum ExportEncoding: String, CaseIterable, Identifiable {
    case shiftJIS = "Shift_JIS"
    case utf8 = "UTF-8"
    var id: String { rawValue }
}

@MainActor
final class InventoryStore: ObservableObject {
    @Published private(set) var items: [InventoryItem] = []
    private var index: [String: Int] = [:]

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("inventory.json")
    }

    init() {
        load()
    }

    // MARK: 保存
    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([InventoryItem].self, from: data) {
            items = decoded
        } else {
            migrateOldData()
        }
        rebuildIndex()
    }

    private func migrateOldData() {
        struct Old: Codable { let jan: String; var name: String; var count: Int; var updatedAt: Date }
        guard let data = UserDefaults.standard.data(forKey: "saved_jan_products_v1"),
              let old = try? JSONDecoder().decode([Old].self, from: data) else { return }
        items = old.map {
            InventoryItem(code: $0.jan, ownCode: "", name: $0.name, hinban: "", unit: "",
                          bookQty: nil, count: $0.count, countedAt: $0.updatedAt, aliases: nil)
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func rebuildIndex() {
        index = [:]
        for (i, item) in items.enumerated() {
            for a in item.aliases ?? [] where index[Self.key(a)] == nil {
                index[Self.key(a)] = i
            }
        }
        for (i, item) in items.enumerated() {
            index[Self.key(item.code)] = i
        }
    }

    private static func key(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    // MARK: 検索
    func find(_ scanned: String) -> InventoryItem? {
        findIndex(scanned).map { items[$0] }
    }

    private func findIndex(_ scanned: String) -> Int? {
        let k = Self.key(scanned)
        if let i = index[k] { return i }
        // UPC-A（12桁）とEAN-13（先頭0付き）の違いを吸収
        if k.count == 13, k.hasPrefix("0"), let i = index[String(k.dropFirst())] { return i }
        if k.count == 12, k.allSatisfy({ $0.isNumber }), let i = index["0" + k] { return i }
        // 自社コードで一致
        if let i = items.firstIndex(where: { !$0.ownCode.isEmpty && Self.key($0.ownCode) == k }) { return i }
        return nil
    }

    // MARK: 更新
    /// 読み取り時に +1。見つかった商品を返す
    func increment(_ scanned: String) -> InventoryItem? {
        guard let i = findIndex(scanned) else { return nil }
        items[i].count = (items[i].count ?? 0) + 1
        items[i].countedAt = Date()
        save()
        return items[i]
    }

    func setCount(code: String, count: Int?) {
        guard let i = findIndex(code) else { return }
        items[i].count = count.map { max(0, $0) }
        items[i].countedAt = count == nil ? nil : Date()
        save()
    }

    func upsert(_ item: InventoryItem) {
        if let i = findIndex(item.code) {
            items[i] = item
        } else {
            items.insert(item, at: 0)
        }
        save()
        rebuildIndex()
    }

    /// 読み取ったバーコードを既存の商品にひも付ける
    func link(alias: String, to code: String) {
        guard let i = items.firstIndex(where: { $0.code == code }) else { return }
        let a = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, Self.key(a) != Self.key(code) else { return }
        var list = items[i].aliases ?? []
        if !list.contains(where: { Self.key($0) == Self.key(a) }) { list.append(a) }
        items[i].aliases = list
        save()
        rebuildIndex()
    }

    func unlink(alias: String, from code: String) {
        guard let i = items.firstIndex(where: { $0.code == code }) else { return }
        items[i].aliases?.removeAll { Self.key($0) == Self.key(alias) }
        save()
        rebuildIndex()
    }

    func delete(codes: [String]) {
        let keys = Set(codes.map(Self.key))
        items.removeAll { keys.contains(Self.key($0.code)) }
        save()
        rebuildIndex()
    }

    func resetCounts() {
        for i in items.indices { items[i].count = nil; items[i].countedAt = nil }
        save()
    }

    func deleteAll() {
        items = []
        save()
        rebuildIndex()
    }

    // MARK: 読み込み
    struct ImportResult { var added = 0; var updated = 0; var skipped = 0 }

    func importFile(url: URL) throws -> ImportResult {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let table: [[String]]
        if url.pathExtension.lowercased() == "xlsx" || data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            table = try XLSXReader.readFirstSheet(data: data)
        } else {
            guard let text = CSV.decode(data) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            table = CSV.parse(text)
        }
        return importTable(table)
    }

    private struct Columns {
        var code: Int?, own: Int?, name: Int?, hinban: Int?, unit: Int?, book: Int?, count: Int?, alias: Int?
    }

    private func detectColumns(_ row: [String]) -> Columns? {
        func idx(_ names: [String]) -> Int? {
            for n in names {
                if let i = row.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == n }) { return i }
            }
            return nil
        }
        var c = Columns()
        c.code = idx(["バーコード", "JANコード", "JAN", "ＪＡＮコード", "コード"])
        c.own = idx(["自社コード", "品目コード"])
        c.name = idx(["品名", "商品名", "品目名"])
        c.hinban = idx(["品番", "型番"])
        c.unit = idx(["単位"])
        c.book = idx(["帳簿数", "現品数", "帳簿在庫数", "在庫数"])
        c.count = idx(["実数", "棚卸数", "数量"])
        c.alias = idx(["ひも付けバーコード"])
        return (c.code != nil && (c.name != nil || c.count != nil)) ? c : nil
    }

    private func importTable(_ table: [[String]]) -> ImportResult {
        var result = ImportResult()
        var cols: Columns?
        var start = 0
        for (i, row) in table.prefix(10).enumerated() {
            if let c = detectColumns(row) { cols = c; start = i + 1; break }
        }
        // 見出しが無い場合：1列目=コード、2列目=品名、3列目=数量
        let c = cols ?? Columns(code: 0, own: nil, name: 1, hinban: nil, unit: nil, book: nil, count: 2, alias: nil)
        func cell(_ row: [String], _ i: Int?) -> String? {
            guard let i, i < row.count else { return nil }
            return row[i].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func number(_ s: String?) -> Int? {
            guard let s, !s.isEmpty else { return nil }
            if let n = Int(s) { return n }
            if let d = Double(s) { return Int(d.rounded()) }
            return nil
        }

        for row in table.dropFirst(start) {
            guard var code = cell(row, c.code), !code.isEmpty else {
                if row.contains(where: { !$0.isEmpty }) { result.skipped += 1 }
                continue
            }
            if code.hasPrefix("=") { code.removeFirst() }
            code = code.replacingOccurrences(of: "\"", with: "")

            let existingIndex = findIndex(code)
            var item = existingIndex.map { items[$0] } ??
                InventoryItem(code: code, ownCode: "", name: "", hinban: "", unit: "", bookQty: nil, count: nil, countedAt: nil, aliases: nil)
            if let v = cell(row, c.own), !v.isEmpty { item.ownCode = v }
            if let v = cell(row, c.name), !v.isEmpty { item.name = v }
            if let v = cell(row, c.hinban), !v.isEmpty { item.hinban = v }
            if let v = cell(row, c.unit), !v.isEmpty { item.unit = v }
            if c.book != nil { item.bookQty = number(cell(row, c.book)) }
            if c.count != nil, let n = number(cell(row, c.count)) {
                item.count = n
                item.countedAt = item.countedAt ?? Date()
            }

            var aliasList = item.aliases ?? []
            if let v = cell(row, c.alias), !v.isEmpty {
                for a in v.split(separator: " ").map(String.init) where !aliasList.contains(a) { aliasList.append(a) }
            }
            // 「ST-45132003153」→ 頭の49が置き換わった形なら 4945132003153 もひも付け
            if code.hasPrefix("ST-") {
                let jan = "49" + code.dropFirst(3)
                if Self.isValidJAN(jan) && !aliasList.contains(jan) { aliasList.append(jan) }
            }
            item.aliases = aliasList.isEmpty ? nil : aliasList

            if let i = existingIndex {
                items[i] = item
                result.updated += 1
            } else {
                items.append(item)
                index[Self.key(code)] = items.count - 1
                result.added += 1
            }
        }
        save()
        rebuildIndex()
        return result
    }

    static func isValidJAN(_ code: String) -> Bool {
        guard code.count == 13 || code.count == 8,
              code.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        let digits = code.compactMap { Int(String($0)) }
        var sum = 0
        for (i, d) in digits.dropLast().reversed().enumerated() {
            sum += (i % 2 == 0) ? d * 3 : d
        }
        return (10 - sum % 10) % 10 == digits.last
    }

    // MARK: 書き出し
    func exportCSV(includeUncounted: Bool, encoding: ExportEncoding) -> Data {
        var lines = ["バーコード,自社コード,品名,品番,単位,帳簿数,実数,差異,カウント日時,ひも付けバーコード"]
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/MM/dd HH:mm:ss"
        for item in items {
            if item.count == nil && !includeUncounted { continue }
            let count = item.count ?? 0
            let book = item.bookQty.map(String.init) ?? ""
            let diff = item.bookQty.map { String(count - $0) } ?? ""
            let date = item.countedAt.map { f.string(from: $0) } ?? ""
            let aliases = (item.aliases ?? []).joined(separator: " ")
            lines.append([
                CSV.escape(item.code), CSV.escape(item.ownCode), CSV.escape(item.name),
                CSV.escape(item.hinban), CSV.escape(item.unit), book, String(count), diff, date, CSV.escape(aliases)
            ].joined(separator: ","))
        }
        let text = lines.joined(separator: "\r\n") + "\r\n"
        switch encoding {
        case .utf8:
            return Data("\u{FEFF}".utf8) + Data(text.utf8)
        case .shiftJIS:
            return text.data(using: .shiftJIS, allowLossyConversion: true) ?? Data(text.utf8)
        }
    }
}
