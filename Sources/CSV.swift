import Foundation

enum CSV {
    /// CSV全体を解析（"" で囲まれた中の改行・カンマにも対応）
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var it = Array(text.unicodeScalars)
        if it.first == "\u{FEFF}" { it.removeFirst() }
        var i = 0
        while i < it.count {
            let c = it[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < it.count && it[i + 1] == "\"" { field.unicodeScalars.append("\""); i += 1 }
                    else { inQuotes = false }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\r":
                    row.append(field); field = ""; rows.append(row); row = []
                    if i + 1 < it.count && it[i + 1] == "\n" { i += 1 }
                case "\n":
                    row.append(field); field = ""; rows.append(row); row = []
                default: field.unicodeScalars.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func decode(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .shiftJIS)
    }

    static func escape(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
