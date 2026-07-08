import Foundation
import CoreXLSX
import ZIPFoundation

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

/// One worksheet from a workbook, carrying the tab name the operator sees
/// in Excel. CSV/TSV files produce a single entry named after the file.
struct NamedTable: Equatable {
    let name: String
    let table: SpreadsheetTable
}

/// In-memory representation of a single sheet.
struct SpreadsheetTable: Equatable {
    let headers: [String]
    /// Rows aligned to `headers`. Cells beyond the header count are ignored.
    let rows: [[String]]
    /// Server/file links found in the banner rows above the header — the V1
    /// job sheet carries the artwork folder as a UNC path on its "ARTWORK
    /// AT:" row. In sheet order, deduplicated, verbatim (the app's path
    /// parser handles the normalisation).
    let sourceLinks: [String]

    init(headers: [String], rows: [[String]], sourceLinks: [String] = []) {
        self.headers = headers
        self.rows = rows
        self.sourceLinks = sourceLinks
    }

    /// Sentinel returned by `detectHeaderRow` / used by `from(grid:)` when
    /// nothing in the grid looks like a header.
    static let empty = SpreadsheetTable(headers: [], rows: [])

    // MARK: - Header synonyms

    /// Known header names for each column role, all pre-normalised via
    /// `normaliseHeader`. Job sheets are hand-authored, so we match a small
    /// curated list rather than fuzzy-matching — a wrong guess here would
    /// silently misfile artwork.
    static let fileSynonyms = [
        "file name", "filename", "file", "name", "artwork",
        "artwork name front", "artwork front", "front artwork",
    ]
    static let backFileSynonyms = [
        "artwork name back", "artwork back", "back artwork",
    ]
    static let folderSynonyms = [
        "folder name", "folder", "destination", "material", "substrate",
    ]
    static let subfolderSynonyms = [
        "colour spec", "color spec", "subfolder", "sub folder", "sub-folder",
    ]
    static let quantitySynonyms = ["quantity", "qty", "count", "amount"]

    /// Lowercase and collapse whitespace runs, so headers like
    /// "Artwork name  Back" (double space, as seen in real job sheets)
    /// still match their synonym.
    static func normaliseHeader(_ s: String) -> String {
        s.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    // MARK: - Construction from a raw cell grid

    /// Build a table from a raw grid, locating the header row by content.
    ///
    /// Job sheets put several rows of job metadata (title banner, job
    /// number, artwork path) above the real column headers — in the V1
    /// layout the headers live on row 9. We scan the first `searchDepth`
    /// rows for the first row containing both a file synonym and a folder
    /// synonym; everything above it is discarded. When no row qualifies we
    /// fall back to the first non-empty row, which preserves the behaviour
    /// for plain "headers in row 1" sheets with custom column names.
    static func from(grid rawGrid: [[String]], searchDepth: Int = 30) -> SpreadsheetTable {
        var grid = rawGrid
        // Drop fully empty trailing rows (common in hand-edited sheets).
        while let last = grid.last, last.allSatisfy(\.isEmpty) { grid.removeLast() }
        guard !grid.isEmpty else { return .empty }

        let headerIndex = detectHeaderRow(in: grid, searchDepth: searchDepth)
            ?? grid.firstIndex { !$0.allSatisfy(\.isEmpty) }
        guard let headerIndex else { return .empty }

        let headers = grid[headerIndex]
        let body = Array(grid.dropFirst(headerIndex + 1)).filter { !$0.allSatisfy(\.isEmpty) }
        return SpreadsheetTable(
            headers: headers,
            rows: body,
            sourceLinks: extractLinks(fromBanner: grid.prefix(headerIndex))
        )
    }

    /// Pull server/file links out of the banner rows the header detection
    /// is about to discard. Only cells that *look* like an absolute link
    /// qualify — plain banner text like a job name must not be mistaken
    /// for a share-relative path.
    private static func extractLinks(fromBanner rows: ArraySlice<[String]>) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for row in rows {
            for cell in row {
                let t = cell.trimmingCharacters(in: .whitespacesAndNewlines)
                guard looksLikeLink(t), seen.insert(t).inserted else { continue }
                out.append(t)
            }
        }
        return out
    }

    private static func looksLikeLink(_ s: String) -> Bool {
        let lower = s.lowercased()
        return s.hasPrefix("\\\\")
            || lower.hasPrefix("smb://") || lower.hasPrefix("afp://")
            || lower.hasPrefix("cifs://") || lower.hasPrefix("file://")
            || s.hasPrefix("/Volumes/")
    }

    private static func detectHeaderRow(in grid: [[String]], searchDepth: Int) -> Int? {
        for (i, row) in grid.prefix(searchDepth).enumerated() {
            let normalised = Set(row.map(normaliseHeader))
            let hasFile = fileSynonyms.contains(where: normalised.contains)
            let hasFolder = folderSynonyms.contains(where: normalised.contains)
            if hasFile && hasFolder { return i }
        }
        return nil
    }

    // MARK: - Typed rows

    /// Convert the raw table into typed mapping rows by picking the columns
    /// the operator chose. Optional columns take `nil` (or the empty string)
    /// to disable their feature:
    ///
    ///   - `quantityColumn` — `_x<qty>` rename suffix.
    ///   - `backFileColumn` — a second artwork file per sheet row (the V1
    ///     job sheet's "Artwork name Back"); rows with a value there emit
    ///     an extra `MappingRow` with the same destination and quantity.
    ///   - `subfolderColumn` — nests the destination one level deeper:
    ///     `<folder>/<subfolder>` (the V1 job sheet's Material/Colour Spec).
    ///
    /// Cell values used as folder names are sanitised: `/` and `:` become
    /// `-`, because colour specs like "4/0 - Print to Face" would otherwise
    /// silently create an extra folder level. Nesting only ever comes from
    /// the explicit subfolder column, never from characters inside a cell.
    ///
    /// Rows that reference the same file into the same destination (the job
    /// sheet lists multi-page artwork once per page) collapse into one row.
    /// If the merged rows disagree on quantity, the quantity is dropped —
    /// no rename beats a wrong rename.
    func mappingRows(
        fileColumn: String,
        folderColumn: String,
        quantityColumn: String? = nil,
        backFileColumn: String? = nil,
        subfolderColumn: String? = nil
    ) throws -> [MappingRow] {
        let lower = headers.map { $0.lowercased() }
        func index(of column: String) throws -> Int {
            guard let i = lower.firstIndex(of: column.lowercased()) else {
                throw SpreadsheetError.missingColumn(name: column, available: headers)
            }
            return i
        }
        // Optional columns: absent/empty disables the feature, but a named
        // column that isn't in the sheet throws — silent fallback would
        // hide a typo.
        func optionalIndex(of column: String?) throws -> Int? {
            guard let column, !column.isEmpty else { return nil }
            return try index(of: column)
        }

        let fileIdx = try index(of: fileColumn)
        let folderIdx = try index(of: folderColumn)
        let qtyIdx = try optionalIndex(of: quantityColumn)
        let backIdx = try optionalIndex(of: backFileColumn)
        let subIdx = try optionalIndex(of: subfolderColumn)

        func cell(_ row: [String], _ idx: Int?) -> String {
            guard let idx, idx < row.count else { return "" }
            return row[idx].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var out: [MappingRow] = []
        // Key = normalised filename + destination; value = index into `out`.
        var seen: [String: Int] = [:]

        func emit(id: Int, fileName: String, folderName: String, qty: String?) {
            // sheetKey so "foo.pdf" and "foo" rows pointing at the same
            // destination collapse — they can only ever match one file.
            let key = MatchEngine.sheetKey(fileName) + "\u{1}" + MatchEngine.normalise(folderName)
            if let existing = seen[key] {
                if out[existing].quantity != qty {
                    out[existing].quantity = nil
                }
                return
            }
            seen[key] = out.count
            out.append(MappingRow(id: id, fileName: fileName, folderName: folderName, quantity: qty))
        }

        for (n, row) in rows.enumerated() {
            let folder = cell(row, folderIdx)
            if folder.isEmpty { continue }

            let sub = cell(row, subIdx)
            var folderName = Self.sanitiseFolderComponent(folder)
            if !sub.isEmpty {
                folderName += "/" + Self.sanitiseFolderComponent(sub)
            }

            let rawQty = cell(row, qtyIdx)
            let qty: String? = rawQty.isEmpty ? nil : rawQty

            // ids stay unique and stable per sheet row with the back file
            // interleaved: front = 2n, back = 2n+1.
            let front = cell(row, fileIdx)
            if !front.isEmpty {
                emit(id: 2 * n, fileName: front, folderName: folderName, qty: qty)
            }
            let back = cell(row, backIdx)
            if !back.isEmpty {
                emit(id: 2 * n + 1, fileName: back, folderName: folderName, qty: qty)
            }
        }
        return out
    }

    /// Make a cell value safe to use as a single folder name. `/` would
    /// create an unintended extra folder level (colour specs like "4/0"
    /// are common) and `:` is the legacy HFS separator that Finder still
    /// remaps — both become "-".
    static func sanitiseFolderComponent(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Column autodetection

    struct DetectedColumns {
        var file: String?
        var backFile: String?
        var folder: String?
        var subfolder: String?
        var quantity: String?

        /// How many roles were confidently detected — used to pick the most
        /// plausible worksheet in a multi-sheet workbook.
        var score: Int {
            [file, backFile, folder, subfolder, quantity].compactMap { $0 }.count
        }
    }

    /// Best-effort autodetection of each column role by header name. Picks
    /// the first header (case/whitespace-insensitive) matching a known
    /// synonym for the role.
    func detectColumns() -> DetectedColumns {
        let normalised = headers.map(Self.normaliseHeader)
        func first(matching synonyms: [String]) -> String? {
            headers.indices.first { synonyms.contains(normalised[$0]) }.map { headers[$0] }
        }
        return DetectedColumns(
            file: first(matching: Self.fileSynonyms),
            backFile: first(matching: Self.backFileSynonyms),
            folder: first(matching: Self.folderSynonyms),
            subfolder: first(matching: Self.subfolderSynonyms),
            quantity: first(matching: Self.quantitySynonyms)
        )
    }
}

enum SpreadsheetReader {

    /// Read every worksheet in the file. CSV/TSV yield a single table named
    /// after the file; XLSX yields one entry per worksheet, in workbook
    /// order, so the UI can offer a picker.
    static func readWorkbook(_ url: URL) throws -> [NamedTable] {
        switch url.pathExtension.lowercased() {
        case "csv":
            return [NamedTable(name: url.lastPathComponent,
                               table: try readDelimited(url, separator: ","))]
        case "tsv":
            return [NamedTable(name: url.lastPathComponent,
                               table: try readDelimited(url, separator: "\t"))]
        case "xlsx":
            return try readXLSX(url)
        default:
            throw SpreadsheetError.unsupportedFormat(url.pathExtension)
        }
    }

    /// Convenience for callers that just want "the" sheet: the best-scoring
    /// worksheet per `bestTable`, or an empty table for an empty workbook.
    static func read(_ url: URL) throws -> SpreadsheetTable {
        let tables = try readWorkbook(url)
        return bestTable(in: tables)?.table ?? .empty
    }

    /// The worksheet most likely to be the job table: highest column-
    /// detection score wins, earlier sheet breaks ties. A single-sheet
    /// workbook always returns that sheet, scored or not.
    static func bestTable(in tables: [NamedTable]) -> NamedTable? {
        guard tables.count > 1 else { return tables.first }
        return tables.max { a, b in
            let (sa, sb) = (a.table.detectColumns().score, b.table.detectColumns().score)
            // max(by:) keeps the *later* element on ties; compare strictly
            // so the earlier sheet survives a tie instead.
            return sa < sb
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
        return SpreadsheetTable.from(grid: rows)
    }

    // MARK: - XLSX

    private static func readXLSX(_ url: URL) throws -> [NamedTable] {
        guard let file = XLSXFile(filepath: url.path) else {
            throw SpreadsheetError.readFailed("Could not open .xlsx at \(url.path)")
        }
        do {
            let shared = try file.parseSharedStrings()
            var out: [NamedTable] = []
            for (name, path) in try worksheetPathsAndNames(in: file, fileURL: url) {
                let worksheet = try file.parseWorksheet(at: path)
                let grid = assembleGrid(from: worksheet, sharedStrings: shared)
                out.append(NamedTable(
                    name: name ?? "Sheet \(out.count + 1)",
                    table: SpreadsheetTable.from(grid: grid)
                ))
            }
            return out
        } catch {
            throw SpreadsheetError.readFailed(error.localizedDescription)
        }
    }

    /// Worksheet names and part paths, in tab order.
    ///
    /// CoreXLSX's relationship decoder is a strict enum, so a workbook
    /// whose relationship list mentions a type it doesn't model — modern
    /// Excel adds `sheetMetadata` and friends — fails wholesale, even
    /// though every worksheet inside parses fine. Real V1 job sheets hit
    /// this. When CoreXLSX refuses, fall back to reading the two structure
    /// XMLs ourselves, ignoring anything unrecognised.
    private static func worksheetPathsAndNames(
        in file: XLSXFile, fileURL: URL
    ) throws -> [(name: String?, path: String)] {
        if let workbook = try? file.parseWorkbooks().first,
           let pairs = try? file.parseWorksheetPathsAndNames(workbook: workbook),
           !pairs.isEmpty {
            return pairs
        }
        return try fallbackWorksheetPathsAndNames(fileURL: fileURL)
    }

    private static func fallbackWorksheetPathsAndNames(
        fileURL: URL
    ) throws -> [(name: String?, path: String)] {
        let archive = try Archive(url: fileURL, accessMode: .read)
        func part(_ path: String) throws -> Data {
            guard let entry = archive[path] else {
                throw SpreadsheetError.readFailed("\(path) missing from workbook")
            }
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            return data
        }

        // xl/workbook.xml lists the sheets in tab order: name + r:id.
        let sheets = XMLAttributeCollector.collect(element: "sheet", in: try part("xl/workbook.xml"))
        // xl/_rels/workbook.xml.rels maps r:id → part path.
        let rels = XMLAttributeCollector.collect(
            element: "Relationship", in: try part("xl/_rels/workbook.xml.rels")
        )
        var targets: [String: String] = [:]
        for rel in rels {
            if let id = rel["Id"], let target = rel["Target"] {
                targets[id] = target
            }
        }

        return sheets.compactMap { sheet in
            guard let rId = sheet["r:id"], let target = targets[rId] else { return nil }
            // Targets are relative to xl/ unless they start with "/".
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            return (sheet["name"], path)
        }
    }

    /// Minimal XMLParser delegate: collect the attribute dictionaries of
    /// every element with a given (namespace-stripped) name.
    private final class XMLAttributeCollector: NSObject, XMLParserDelegate {
        private let elementName: String
        private var collected: [[String: String]] = []

        private init(elementName: String) { self.elementName = elementName }

        static func collect(element: String, in data: Data) -> [[String: String]] {
            let collector = XMLAttributeCollector(elementName: element)
            let parser = XMLParser(data: data)
            parser.delegate = collector
            parser.parse()
            return collector.collected
        }

        func parser(
            _ parser: XMLParser,
            didStartElement name: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            if local == elementName { collected.append(attributes) }
        }
    }

    /// Build a rectangular grid from a worksheet's sparse cell list.
    ///
    /// XLSX stores only cells that have content: a row whose B cell is
    /// empty serialises as [A, C, …], so appending `row.cells` in array
    /// order shifts every later value one column left. Each cell carries
    /// its column reference — place values by that index and pad the gaps,
    /// so a value always lands under the header Excel showed it beneath.
    private static func assembleGrid(from worksheet: Worksheet, sharedStrings: SharedStrings?) -> [[String]] {
        let columnA = ColumnReference("A")!
        var grid: [[String]] = []
        for row in worksheet.data?.rows ?? [] {
            var values: [String] = []
            for cell in row.cells {
                let index = columnA.distance(to: cell.reference.column)
                guard index >= 0 else { continue }
                while values.count < index { values.append("") }
                let text = cellText(cell, sharedStrings: sharedStrings)
                if values.count == index {
                    values.append(text)
                } else {
                    values[index] = text
                }
            }
            grid.append(values)
        }
        return grid
    }

    private static func cellText(_ cell: Cell, sharedStrings: SharedStrings?) -> String {
        if let shared = sharedStrings, let s = cell.stringValue(shared) { return s }
        if let inline = cell.inlineString?.text { return inline }
        return cell.value ?? ""
    }
}
