import Foundation
import CoreXLSX

enum SpreadsheetError: LocalizedError {
    case unsupportedFormat(String)
    case missingColumn(name: String, available: [String])
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Unsupported spreadsheet format: .\(ext). Try .xlsx, .csv or .tsv."
        case .missingColumn(let name, let have):
            return "Spreadsheet must contain a column named '\(name)'. Found: \(have.joined(separator: ", "))."
        case .readFailed(let msg):
            return "Could not read spreadsheet: \(msg)"
        }
    }
}

/// In-memory representation of a single sheet.
struct SpreadsheetTable: Equatable {
    let headers: [String]
    /// Rows aligned to `headers`. Cells beyond the header count are ignored.
    let rows: [[String]]

    /// Convert the raw table into typed mapping rows by picking two columns.
    func mappingRows(fileColumn: String, folderColumn: String) throws -> [MappingRow] {
        let lower = headers.map { $0.lowercased() }
        guard let fileIdx = lower.firstIndex(of: fileColumn.lowercased()) else {
            throw SpreadsheetError.missingColumn(name: fileColumn, available: headers)
        }
        guard let folderIdx = lower.firstIndex(of: folderColumn.lowercased()) else {
            throw SpreadsheetError.missingColumn(name: folderColumn, available: headers)
        }
        var out: [MappingRow] = []
        for (n, row) in rows.enumerated() {
            guard fileIdx < row.count, folderIdx < row.count else { continue }
            let f = row[fileIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            let g = row[folderIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            if f.isEmpty || g.isEmpty { continue }
            out.append(MappingRow(id: n, fileName: f, folderName: g))
        }
        return out
    }

    /// Best-effort autodetection of the file/folder columns by header name.
    /// Picks the first header (case-insensitive) that matches a known synonym.
    func detectColumns() -> (file: String?, folder: String?) {
        let fileSyns = ["file name", "filename", "file", "name", "artwork"]
        let folderSyns = ["folder name", "folder", "destination", "material", "substrate"]
        let lower = headers.map { $0.lowercased() }
        let file = headers.indices.first { fileSyns.contains(lower[$0]) }.map { headers[$0] }
        let folder = headers.indices.first { folderSyns.contains(lower[$0]) }.map { headers[$0] }
        return (file, folder)
    }
}

enum SpreadsheetReader {
    static func read(_ url: URL) throws -> SpreadsheetTable {
        switch url.pathExtension.lowercased() {
        case "csv":  return try readDelimited(url, separator: ",")
        case "tsv":  return try readDelimited(url, separator: "\t")
        case "xlsx": return try readXLSX(url)
        default:     throw SpreadsheetError.unsupportedFormat(url.pathExtension)
        }
    }

    // MARK: - CSV/TSV

    /// Minimal RFC-4180-ish parser. Handles quoted fields with embedded
    /// separators, doubled-quote escapes, and CRLF line endings.
    private static func readDelimited(_ url: URL, separator: Character) throws -> SpreadsheetTable {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Try Latin-1 as a last resort — Excel sometimes exports legacy CSVs.
            guard let alt = try? String(contentsOf: url, encoding: .isoLatin1) else {
                throw SpreadsheetError.readFailed(error.localizedDescription)
            }
            return parseDelimited(alt, separator: separator)
        }
        return parseDelimited(text, separator: separator)
    }

    private static func parseDelimited(_ text: String, separator: Character) -> SpreadsheetTable {
        let chars = Array(text)
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else {
                switch ch {
                case "\"":
                    inQuotes = true
                case separator:
                    row.append(field); field = ""
                case "\n":
                    row.append(field); field = ""
                    rows.append(row); row = []
                case "\r":
                    break  // ignore; \n handles row break
                default:
                    field.append(ch)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        guard let header = rows.first else { return SpreadsheetTable(headers: [], rows: []) }
        let body = Array(rows.dropFirst()).filter { !$0.allSatisfy(\.isEmpty) }
        return SpreadsheetTable(headers: header, rows: body)
    }

    // MARK: - XLSX

    private static func readXLSX(_ url: URL) throws -> SpreadsheetTable {
        guard let file = XLSXFile(filepath: url.path) else {
            throw SpreadsheetError.readFailed("Could not open .xlsx at \(url.path)")
        }
        do {
            let shared = try file.parseSharedStrings()
            let workbooks = try file.parseWorkbooks()
            guard let workbook = workbooks.first,
                  let sheetPath = (try file.parseWorksheetPathsAndNames(workbook: workbook)).first?.path else {
                return SpreadsheetTable(headers: [], rows: [])
            }
            let worksheet = try file.parseWorksheet(at: sheetPath)
            var grid: [[String]] = []
            for row in worksheet.data?.rows ?? [] {
                var values: [String] = []
                for cell in row.cells {
                    values.append(cellText(cell, sharedStrings: shared))
                }
                grid.append(values)
            }
            // Drop fully empty trailing rows (common in hand-edited sheets).
            while let last = grid.last, last.allSatisfy(\.isEmpty) { grid.removeLast() }
            guard let header = grid.first else { return SpreadsheetTable(headers: [], rows: []) }
            let body = Array(grid.dropFirst()).filter { !$0.allSatisfy(\.isEmpty) }
            return SpreadsheetTable(headers: header, rows: body)
        } catch {
            throw SpreadsheetError.readFailed(error.localizedDescription)
        }
    }

    private static func cellText(_ cell: Cell, sharedStrings: SharedStrings?) -> String {
        if let shared = sharedStrings, let s = cell.stringValue(shared) { return s }
        if let inline = cell.inlineString?.text { return inline }
        return cell.value ?? ""
    }
}
