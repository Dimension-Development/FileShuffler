import Foundation

/// Physical size of a single PDF page, in millimetres.
///
/// `usedFallback` is true when the file didn't define an explicit `TrimBox`,
/// so we measured from the `MediaBox` instead. In a print-prepress context
/// this almost always means the file was exported without a separate trim
/// definition — useful for the operator to spot in the report.
struct PageSize: Equatable, Sendable {
    let pageNumber: Int          // 1-indexed
    let widthMm: Double
    let heightMm: Double
    let usedFallback: Bool
}

/// All pages of a single file, plus a graceful failure path.
///
/// `error` is only populated when extraction failed entirely (file unreadable
/// by PDFKit, missing, etc.). When `error` is set, `pages` is empty so the
/// CSV builder can write a single "couldn't read" row instead of skipping
/// the file silently.
struct FilePageSizes: Sendable {
    let url: URL
    let pages: [PageSize]
    let totalPages: Int
    let error: String?

    var failed: Bool { error != nil }
}
