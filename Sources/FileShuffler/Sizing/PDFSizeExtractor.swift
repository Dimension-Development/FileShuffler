import Foundation
import PDFKit
import CoreGraphics

/// Extracts physical page dimensions from PDF (and PDF-compatible `.ai`)
/// files using PDFKit. Output is in millimetres, prefering each page's
/// declared `TrimBox` and falling back to `MediaBox` when no TrimBox is
/// set — which matches what print prepress tools do.
enum PDFSizeExtractor {

    /// Extract page sizes from one file.
    ///
    /// PDFKit returns `nil` for files it can't parse — old `.ai` files saved
    /// without "PDF Compatibility", text files that happen to have a `.pdf`
    /// extension, files that don't exist. We surface those as an error
    /// rather than throwing, so the calling code can include a "couldn't
    /// read" row in the CSV instead of bailing on the whole report.
    static func extract(from url: URL) -> FilePageSizes {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return FilePageSizes(url: url, pages: [], totalPages: 0,
                                 error: "File not found")
        }
        guard let pdf = PDFDocument(url: url) else {
            return FilePageSizes(url: url, pages: [], totalPages: 0,
                                 error: "PDFKit could not open this file")
        }
        let count = pdf.pageCount
        guard count > 0 else {
            return FilePageSizes(url: url, pages: [], totalPages: 0,
                                 error: "PDF has no pages")
        }
        var pages: [PageSize] = []
        pages.reserveCapacity(count)
        for i in 0..<count {
            guard let page = pdf.page(at: i) else { continue }
            let trimDefined = pageHasExplicitTrimBox(page)
            let box: PDFDisplayBox = trimDefined ? .trimBox : .mediaBox
            let bounds = page.bounds(for: box)
            pages.append(PageSize(
                pageNumber: i + 1,
                widthMm: pointsToMm(Double(bounds.width)),
                heightMm: pointsToMm(Double(bounds.height)),
                usedFallback: !trimDefined
            ))
        }
        return FilePageSizes(url: url, pages: pages, totalPages: count, error: nil)
    }

    /// Extract from many files. Sequential — page reads are fast (single-
    /// digit ms each on typical artwork) so a thread pool would cost more
    /// in coordination than it'd save in wall time for the ~50-file jobs
    /// this app deals with.
    static func extract(from urls: [URL]) -> [FilePageSizes] {
        urls.map(extract(from:))
    }

    // MARK: - Internals

    /// Inspect the page's raw PDF dictionary for an explicit `/TrimBox`
    /// entry. PDFKit's `bounds(for: .trimBox)` silently falls back to
    /// MediaBox when no TrimBox is defined, so we can't tell from PDFKit
    /// alone which box we're getting — drop down to CoreGraphics.
    private static func pageHasExplicitTrimBox(_ page: PDFPage) -> Bool {
        guard let cgPage = page.pageRef else { return false }
        guard let dict = cgPage.dictionary else { return false }
        var array: CGPDFArrayRef?
        return CGPDFDictionaryGetArray(dict, "TrimBox", &array)
    }

    /// 1 PDF point = 1/72 inch; 1 inch = 25.4 mm.
    private static func pointsToMm(_ points: Double) -> Double {
        points * 25.4 / 72.0
    }
}
