import Foundation

/// Builds a report of page dimensions for a set of files, intended to be
/// written next to the audit log after an apply. Exported as .xlsx (so
/// problem rows can be colour-highlighted); `csv()` remains for anything
/// that wants the same table as plain text.
///
/// Columns (one row per page; one row per failed-to-read file; one row per
/// sheet row that never matched a file on disk):
///   Source filename, Destination folder, Page, Width (mm), Height (mm),
///   Total pages, Spot colours, Notes
struct SizesReport {
    let baseFolder: URL
    let files: [FilePageSizes]
    /// Sheet rows the matcher couldn't pair with any file on disk. They're
    /// appended after the measured files so the report also answers "what
    /// was on the job sheet but never found?" — highlighted red in the xlsx.
    let missing: [MappingRow]
    let generatedAt: Date

    init(
        baseFolder: URL,
        files: [FilePageSizes],
        missing: [MappingRow] = [],
        generatedAt: Date = Date()
    ) {
        self.baseFolder = baseFolder
        self.files = files
        self.missing = missing
        self.generatedAt = generatedAt
    }

    static let missingFileNote = "File not found — on the job sheet but no matching file in the source folders"

    /// What a table row represents — drives the highlight colour in xlsx.
    private enum RowKind {
        case page        // normal measured page
        case unreadable  // file existed but PDFKit couldn't open it
        case missing     // sheet row with no file on disk
    }

    /// The shared table body: same rows in the same order for CSV and xlsx.
    private func tableRows() -> [(fields: [String], kind: RowKind)] {
        var rows: [(fields: [String], kind: RowKind)] = []
        let basePath = baseFolder.standardizedFileURL.path

        for file in files {
            let filename = file.url.lastPathComponent
            let folder = relativeParent(of: file.url, base: basePath)

            if let err = file.error {
                rows.append((
                    [filename, folder, "", "", "", "", "", "Couldn't read: \(err)"],
                    .unreadable
                ))
                continue
            }

            for page in file.pages {
                let note = page.usedFallback ? "TrimBox not defined, used MediaBox" : ""
                // Multiple spots in one cell: semicolon-separated so commas
                // inside Pantone names (rare but possible) don't trip the
                // CSV parser. Verbatim from the PDF, no normalisation.
                let spots = page.spotColours.joined(separator: "; ")
                rows.append((
                    [
                        filename,
                        folder,
                        String(page.pageNumber),
                        formatMm(page.widthMm),
                        formatMm(page.heightMm),
                        String(file.totalPages),
                        spots,
                        note
                    ],
                    .page
                ))
            }
        }

        for row in missing {
            rows.append((
                [row.fileName, row.folderName, "", "", "", "", "", Self.missingFileNote],
                .missing
            ))
        }

        return rows
    }

    /// Build the CSV body. The leading header row is always emitted so the
    /// CSV is self-describing when opened in Excel/Numbers.
    func csv() -> String {
        let rows = [Self.headers] + tableRows().map(\.fields)
        return rows.map(csvLine).joined(separator: "\r\n") + "\r\n"
        // CRLF line endings keep Excel on Windows happy; macOS Excel and
        // Numbers handle either.
    }

    /// The same table as a real workbook: bold header, missing-file rows
    /// filled red, unreadable-file rows filled amber, dimension columns as
    /// actual numbers so they sort correctly.
    func xlsx() throws -> Data {
        var rows: [MinimalXLSX.Row] = [
            MinimalXLSX.Row(cells: Self.headers.map { .text($0) }, style: .header)
        ]
        // Page, Width, Height, Total pages — always our own numeric
        // formatting, never free text, so a plain <v> cell is safe.
        let numericColumns: Set<Int> = [2, 3, 4, 5]

        for (fields, kind) in tableRows() {
            let style: MinimalXLSX.RowStyle
            switch kind {
            case .page: style = .body
            case .unreadable: style = .amberHighlight
            case .missing: style = .redHighlight
            }
            let cells = fields.enumerated().map { index, field -> MinimalXLSX.Cell in
                if field.isEmpty { return .empty }
                return numericColumns.contains(index) ? .number(field) : .text(field)
            }
            rows.append(MinimalXLSX.Row(cells: cells, style: style))
        }

        return try MinimalXLSX.workbook(
            sheetName: "Sizes",
            columnWidths: Self.columnWidths,
            rows: rows
        )
    }

    static let headers: [String] = [
        "Source filename",
        "Destination folder",
        "Page",
        "Width (mm)",
        "Height (mm)",
        "Total pages",
        "Spot colours",
        "Notes"
    ]

    /// Excel column widths (in character units) matching `headers` —
    /// generous filename/notes columns, narrow numeric ones.
    static let columnWidths: [Double] = [42, 28, 7, 11, 11, 11, 26, 52]

    // MARK: - helpers

    /// Folder of the file relative to the base, e.g.
    /// `200gsm Metro Vibe/...`.  Empty when the file lives directly under
    /// the base; absolute path when it's somehow outside (shouldn't happen
    /// in practice but we don't want to silently elide that case).
    private func relativeParent(of url: URL, base: String) -> String {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        if parent == base { return "" }
        if parent.hasPrefix(base + "/") {
            return String(parent.dropFirst(base.count + 1))
        }
        return parent
    }

    private func formatMm(_ mm: Double) -> String {
        // 1 dp matches the typical print-prepress precision; sub-mm rarely
        // matters and trailing zeros in artwork dimensions read as noise.
        String(format: "%.1f", mm)
    }

    private func csvLine(_ fields: [String]) -> String {
        fields.map(csvEscape).joined(separator: ",")
    }

    /// Quote any field that contains a delimiter, quote, or line-break,
    /// doubling embedded quotes per RFC 4180.
    private func csvEscape(_ s: String) -> String {
        let needsQuoting = s.contains(",") || s.contains("\"")
            || s.contains("\n") || s.contains("\r")
        guard needsQuoting else { return s }
        let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
