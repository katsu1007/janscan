import Foundation
import Compression

/// xlsx（Excel）ファイルの1枚目のシートを文字列の表として読み込む
enum XLSXReader {
    enum ReadError: LocalizedError {
        case notZip, missingSheet, inflateFailed
        var errorDescription: String? {
            switch self {
            case .notZip: return "Excelファイルとして読み込めませんでした"
            case .missingSheet: return "シートが見つかりませんでした"
            case .inflateFailed: return "ファイルの展開に失敗しました"
            }
        }
    }

    static func readFirstSheet(data: Data) throws -> [[String]] {
        let zip = try ZipArchive(data: data)
        var shared: [String] = []
        if let ss = try zip.extract("xl/sharedStrings.xml") {
            shared = SharedStringsParser.parse(ss)
        }
        let sheetPath = firstSheetPath(zip: zip)
        guard let path = sheetPath, let sheet = try zip.extract(path) else {
            throw ReadError.missingSheet
        }
        return SheetParser.parse(sheet, shared: shared)
    }

    private static func firstSheetPath(zip: ZipArchive) -> String? {
        // workbook.xml の1枚目のシート → rels でファイル名を解決
        if let wb = try? zip.extract("xl/workbook.xml"),
           let rels = try? zip.extract("xl/_rels/workbook.xml.rels"),
           let rid = WorkbookParser.firstSheetRelId(wb),
           let target = RelsParser.target(for: rid, in: rels) {
            var t = target
            if t.hasPrefix("/") { t.removeFirst() } else { t = "xl/" + t }
            if zip.contains(t) { return t }
        }
        if zip.contains("xl/worksheets/sheet1.xml") { return "xl/worksheets/sheet1.xml" }
        return zip.names.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }.sorted().first
    }
}

// MARK: - 最小限のZIP読み込み
struct ZipArchive {
    private struct Entry {
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }
    private let bytes: [UInt8]
    private var entries: [String: Entry] = [:]
    var names: [String] { Array(entries.keys) }

    init(data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count > 22 else { throw XLSXReader.ReadError.notZip }
        var eocd = -1
        var i = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 65535)
        while i >= lowest {
            if u32(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw XLSXReader.ReadError.notZip }
        let count = Int(u16(eocd + 10))
        var p = Int(u32(eocd + 16))
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(p) == 0x02014b50 else { break }
            let method = u16(p + 10)
            let cSize = Int(u32(p + 20))
            let uSize = Int(u32(p + 24))
            let nameLen = Int(u16(p + 28))
            let extraLen = Int(u16(p + 30))
            let commentLen = Int(u16(p + 32))
            let offset = Int(u32(p + 42))
            guard p + 46 + nameLen <= bytes.count else { break }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            entries[name] = Entry(method: method, compressedSize: cSize, uncompressedSize: uSize, localHeaderOffset: offset)
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    func extract(_ name: String) throws -> Data? {
        guard let e = entries[name] else { return nil }
        let h = e.localHeaderOffset
        guard h + 30 <= bytes.count, u32(h) == 0x04034b50 else { throw XLSXReader.ReadError.notZip }
        let start = h + 30 + Int(u16(h + 26)) + Int(u16(h + 28))
        let end = start + e.compressedSize
        guard end <= bytes.count else { throw XLSXReader.ReadError.notZip }
        let src = Array(bytes[start..<end])
        if e.method == 0 || src.isEmpty { return Data(src) }
        guard e.method == 8 else { throw XLSXReader.ReadError.inflateFailed }
        let capacity = max(e.uncompressedSize, 1)
        var dst = [UInt8](repeating: 0, count: capacity)
        let written = src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                compression_decode_buffer(d.baseAddress!, capacity, s.baseAddress!, s.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw XLSXReader.ReadError.inflateFailed }
        return Data(dst[0..<written])
    }

    private func u16(_ i: Int) -> UInt16 { UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 }
    private func u32(_ i: Int) -> UInt32 {
        UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
    }
}

// MARK: - XMLパーサー
private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var result: [String] = []
    private var current = ""
    private var inSI = false
    private var inT = false
    private var phoneticDepth = 0

    static func parse(_ data: Data) -> [String] {
        let p = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.result
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "si": inSI = true; current = ""
        case "rPh": phoneticDepth += 1   // ふりがなは無視
        case "t": inT = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch name {
        case "si": result.append(current); inSI = false
        case "rPh": phoneticDepth -= 1
        case "t": inT = false
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inSI && inT && phoneticDepth == 0 { current += string }
    }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    private let shared: [String]
    private var rows: [[String]] = []
    private var currentRow: [Int: String] = [:]
    private var cellRef = ""
    private var cellType = ""
    private var value = ""
    private var inValue = false
    private var inInlineT = false
    private var nextCol = 0

    init(shared: [String]) { self.shared = shared }

    static func parse(_ data: Data, shared: [String]) -> [[String]] {
        let p = SheetParser(shared: shared)
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.rows
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "row":
            currentRow = [:]; nextCol = 0
            if let r = attributes["r"], let n = Int(r) {
                while rows.count < n - 1 { rows.append([]) }
            }
        case "c":
            cellRef = attributes["r"] ?? ""
            cellType = attributes["t"] ?? "n"
            value = ""
        case "v": inValue = true
        case "t": if cellType == "inlineStr" { inInlineT = true }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch name {
        case "v": inValue = false
        case "t": inInlineT = false
        case "c":
            let col = SheetParser.columnIndex(cellRef) ?? nextCol
            currentRow[col] = resolve()
            nextCol = col + 1
        case "row":
            let maxCol = currentRow.keys.max() ?? -1
            var arr = [String](repeating: "", count: maxCol + 1)
            for (k, v) in currentRow { arr[k] = v }
            rows.append(arr)
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue || inInlineT { value += string }
    }

    private func resolve() -> String {
        switch cellType {
        case "s":
            if let i = Int(value), i >= 0, i < shared.count { return shared[i] }
            return ""
        case "n":
            return SheetParser.formatNumber(value)
        default:
            return value
        }
    }

    /// 4.945132011011E+12 のような表記を 4945132011011 に戻す
    static func formatNumber(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return "" }
        if t.allSatisfy({ $0.isNumber || $0 == "-" }) { return t }
        if let d = Decimal(string: t, locale: Locale(identifier: "en_US_POSIX")) {
            var src = d
            var rounded = Decimal()
            NSDecimalRound(&rounded, &src, 0, .plain)
            if rounded == d {
                return NSDecimalNumber(decimal: rounded).stringValue
            }
            return NSDecimalNumber(decimal: d).stringValue
        }
        return t
    }

    static func columnIndex(_ ref: String) -> Int? {
        var n = 0
        var found = false
        for ch in ref.uppercased() {
            guard let a = ch.asciiValue, a >= 65, a <= 90 else { break }
            n = n * 26 + Int(a - 64)
            found = true
        }
        return found ? n - 1 : nil
    }
}

private final class WorkbookParser: NSObject, XMLParserDelegate {
    private var rid: String?
    static func firstSheetRelId(_ data: Data) -> String? {
        let p = WorkbookParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.rid
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        if name == "sheet" && rid == nil {
            rid = attributes["r:id"] ?? attributes.first(where: { $0.key.hasSuffix(":id") })?.value
        }
    }
}

private final class RelsParser: NSObject, XMLParserDelegate {
    private let wanted: String
    private var target: String?
    init(wanted: String) { self.wanted = wanted }
    static func target(for id: String, in data: Data) -> String? {
        let p = RelsParser(wanted: id)
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.target
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        if name == "Relationship", attributes["Id"] == wanted { target = attributes["Target"] }
    }
}
