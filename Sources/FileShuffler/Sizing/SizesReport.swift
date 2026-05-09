import Foundation

/// Builds a CSV report of page dimensions for a set of files, intended to be
/// written next to the audit log after an apply.
///
/// Columns (one row per page; one row per failed-to-read file):
///   Source filename, Destination folder, Page, Width (mm), Height (mm),
///   Total pages, Notes
struct SizesReport {
    let baseFolder: URL
    let files: [FilePageSizes]
    let generatedAt: Date

    init(baseFolder: URL, files: [FilePageSizes], generatedAt: Date = Date()) {
        self.baseFolder = baseFolder
        self.files = files
        self.generatedAt = generatedAt
    }

    /// Build the CSV body. The leading header row is always emitted so the
    /// CSV is self-describing when opened in Excel/Numbers.
    func csv() -> String {
        var rows: [[String]] = [Self.headers]
        let basePath = baseFolder.standardizedFileURL.path

        for file in files {
            let filename = file.url.lastPathComponent
            let folder = relativeParent(of: file.url, base: basePath)

            if let err = file.error {
                rows.append([filename, folder, "", "", "", "", "Couldn't read: \(err)"])
                continue
            }

            for page in file.pages {
                let note = page.usedFallback ? "TrimBox not defined, used MediaBox" : ""
                rows.append([
                    filename,
                    folder,
                    String(page.pageNumber),
                    formatMm(page.widthMm),
                    formatMm(page.heightMm),
                    String(file.totalPages),
                    note
                ])
            }
        }

        return rows.map(csvLine).joined(separator: "\r\n") + "\r\n"
        // CRLF line endings keep Excel on Windows happy; macOS Excel and
        // Numbers handle either.
    }

    static let headers: [String] = [
        "Source filename",
        "Destination folder",
        "Page",
        "Width (mm)",
        "Height (mm)",
        "Total pages",
        "Notes"
    ]

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
