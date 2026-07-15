import Foundation
import ZIPFoundation

/// Tiny single-sheet .xlsx writer — just enough for FileShuffler's exported
/// reports. CoreXLSX (our reader) is read-only, and the sizes report needs
/// cell fills to highlight problem rows, which CSV can't express.
///
/// Deliberately minimal: one worksheet, inline strings (no shared-strings
/// table), and a fixed style palette. Anything fancier belongs in a real
/// library.
enum MinimalXLSX {

    /// Visual treatment of a whole row. Raw values are indices into the
    /// `cellXfs` list in `stylesXML` — keep the two in sync.
    enum RowStyle: Int {
        case body = 0
        /// Bold — the header row.
        case header = 1
        /// Excel's stock "Bad" look: red fill, dark-red text.
        case redHighlight = 2
        /// Excel's stock "Neutral" look: amber fill, dark-amber text.
        case amberHighlight = 3
    }

    enum Cell {
        case text(String)
        /// Pre-formatted decimal or integer, e.g. "450.0" — written as a
        /// real number so Excel can sort/sum it.
        case number(String)
        /// No value, but still emitted so row fills span every column.
        case empty
    }

    struct Row {
        let cells: [Cell]
        let style: RowStyle
    }

    /// Assemble a complete workbook. `columnWidths` are Excel width units
    /// (roughly characters in the default font); extra or missing entries
    /// relative to the cell count are fine.
    static func workbook(
        sheetName: String,
        columnWidths: [Double],
        rows: [Row]
    ) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create)
        let parts: [(String, String)] = [
            ("[Content_Types].xml", contentTypesXML),
            ("_rels/.rels", rootRelsXML),
            ("xl/workbook.xml", workbookXML(sheetName: sheetName)),
            ("xl/_rels/workbook.xml.rels", workbookRelsXML),
            ("xl/styles.xml", stylesXML),
            ("xl/worksheets/sheet1.xml", sheetXML(columnWidths: columnWidths, rows: rows))
        ]
        for (path, xml) in parts {
            let data = Data(xml.utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        guard let bytes = archive.data else {
            throw CocoaError(.fileWriteUnknown)
        }
        return bytes
    }

    // MARK: - Parts

    private static let contentTypesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
        """

    private static let rootRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """

    private static func workbookXML(sheetName: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="\(escape(sheetName))" sheetId="1" r:id="rId1"/></sheets></workbook>
        """
    }

    private static let workbookRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """

    /// Fill/font pairs mirror Excel's built-in "Bad" (FFC7CE/9C0006) and
    /// "Neutral" (FFEB9C/9C6500) cell styles so the highlights look native.
    /// fills[0] and fills[1] must stay none/gray125 — Excel reserves them.
    private static let stylesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="4"><font><sz val="12"/><name val="Calibri"/></font><font><b/><sz val="12"/><name val="Calibri"/></font><font><sz val="12"/><color rgb="FF9C0006"/><name val="Calibri"/></font><font><sz val="12"/><color rgb="FF9C6500"/><name val="Calibri"/></font></fonts><fills count="4"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFFC7CE"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFFEB9C"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="4"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="0" fontId="2" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/><xf numFmtId="0" fontId="3" fillId="3" borderId="0" xfId="0" applyFont="1" applyFill="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
        """

    private static func sheetXML(columnWidths: [Double], rows: [Row]) -> String {
        var out = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
            """
        if !columnWidths.isEmpty {
            out += "<cols>"
            for (i, width) in columnWidths.enumerated() {
                out += "<col min=\"\(i + 1)\" max=\"\(i + 1)\" width=\"\(width)\" customWidth=\"1\"/>"
            }
            out += "</cols>"
        }
        out += "<sheetData>"
        for (r, row) in rows.enumerated() {
            let rowNumber = r + 1
            out += "<row r=\"\(rowNumber)\">"
            for (c, cell) in row.cells.enumerated() {
                let ref = "\(columnLetter(c))\(rowNumber)"
                let s = row.style.rawValue
                switch cell {
                case .empty:
                    out += "<c r=\"\(ref)\" s=\"\(s)\"/>"
                case .number(let value):
                    out += "<c r=\"\(ref)\" s=\"\(s)\"><v>\(value)</v></c>"
                case .text(let value):
                    out += "<c r=\"\(ref)\" s=\"\(s)\" t=\"inlineStr\"><is>"
                        + "<t xml:space=\"preserve\">\(escape(value))</t></is></c>"
                }
            }
            out += "</row>"
        }
        out += "</sheetData></worksheet>"
        return out
    }

    // MARK: - Helpers

    /// 0 → A, 25 → Z, 26 → AA …
    private static func columnLetter(_ index: Int) -> String {
        var i = index
        var letters = ""
        repeat {
            letters = String(UnicodeScalar(UInt8(65 + i % 26))) + letters
            i = i / 26 - 1
        } while i >= 0
        return letters
    }

    /// Escapes for both text nodes and attribute values (we quote
    /// attributes with `"`, so it needs escaping too).
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
