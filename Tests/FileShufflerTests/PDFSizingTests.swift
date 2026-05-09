import Testing
import Foundation
import CoreGraphics
@testable import FileShuffler

/// Tests for the page-size extractor and CSV report builder.
///
/// We can't easily ship binary fixture PDFs through the SwiftPM test bundle,
/// so each test that needs a real PDF generates one at runtime via Core
/// Graphics with explicit MediaBox / TrimBox values. That gives us complete
/// control over what each fixture contains, and the tests stay self-
/// contained — no external resources to keep in sync.
@Suite("PDFSizeExtractor")
struct PDFSizeExtractorTests {

    @Test("Single A4 page returns ≈ 210 × 297 mm")
    func singleA4PageReturnsCorrectDimensions() throws {
        let url = try makeFixture(mediaMm: (210, 297))
        defer { try? FileManager.default.removeItem(at: url) }

        let result = PDFSizeExtractor.extract(from: url)
        #expect(result.error == nil)
        #expect(result.totalPages == 1)
        #expect(result.pages.count == 1)
        let page = result.pages[0]
        #expect(page.pageNumber == 1)
        #expect(approx(page.widthMm, 210.0))
        #expect(approx(page.heightMm, 297.0))
    }

    @Test("TrimBox is preferred over MediaBox when defined")
    func trimBoxWinsWhenDefined() throws {
        // 220×307 mm media (with 5 mm bleed each side), 210×297 mm trim.
        let url = try makeFixture(mediaMm: (220, 307), trimMm: (210, 297))
        defer { try? FileManager.default.removeItem(at: url) }

        let result = PDFSizeExtractor.extract(from: url)
        let page = try #require(result.pages.first)
        #expect(approx(page.widthMm, 210.0))
        #expect(approx(page.heightMm, 297.0))
        #expect(page.usedFallback == false)
    }

    @Test("MediaBox is used when no TrimBox is defined, and the fallback flag flips")
    func mediaBoxFallbackWhenNoTrimBox() throws {
        let url = try makeFixture(mediaMm: (725, 38))
        defer { try? FileManager.default.removeItem(at: url) }

        let result = PDFSizeExtractor.extract(from: url)
        let page = try #require(result.pages.first)
        #expect(approx(page.widthMm, 725.0))
        #expect(approx(page.heightMm, 38.0))
        #expect(page.usedFallback == true)
    }

    @Test("Multi-page PDFs return one entry per page in document order")
    func multiPagePdfReturnsOnePerPage() throws {
        let url = try makeFixture(mediaMm: (210, 297), pageCount: 3)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = PDFSizeExtractor.extract(from: url)
        #expect(result.totalPages == 3)
        #expect(result.pages.count == 3)
        #expect(result.pages.map(\.pageNumber) == [1, 2, 3])
    }

    @Test("Missing file returns an error rather than crashing")
    func missingFileReturnsError() {
        let bogus = URL(fileURLWithPath: "/tmp/this-file-does-not-exist-\(UUID().uuidString).pdf")
        let result = PDFSizeExtractor.extract(from: bogus)
        #expect(result.failed)
        #expect(result.pages.isEmpty)
    }

    @Test("Non-PDF data with a .pdf extension returns an error")
    func nonPDFDataReturnsError() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("not-a-pdf-\(UUID().uuidString).pdf")
        try Data("this is plain text, not a PDF".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = PDFSizeExtractor.extract(from: url)
        #expect(result.failed)
        #expect(result.pages.isEmpty)
    }
}

@Suite("SizesReport CSV")
struct SizesReportTests {

    @Test("CSV starts with the documented header row")
    func headerRowIsCorrect() {
        let report = SizesReport(baseFolder: URL(fileURLWithPath: "/x"), files: [])
        let csv = report.csv()
        let firstLine = csv.split(separator: "\r\n").first.map(String.init) ?? ""
        #expect(firstLine == "Source filename,Destination folder,Page,Width (mm),Height (mm),Total pages,Spot colours,Notes")
    }

    @Test("Single-page file renders one data row with empty notes")
    func singlePageRowFormat() {
        let base = URL(fileURLWithPath: "/Users/luke/Desktop/261144")
        let pageURL = base.appendingPathComponent("1250mic Libra GCDB/foo.pdf")
        let file = FilePageSizes(
            url: pageURL,
            pages: [PageSize(pageNumber: 1, widthMm: 750.0, heightMm: 290.0, usedFallback: false)],
            totalPages: 1,
            error: nil
        )
        let csv = SizesReport(baseFolder: base, files: [file]).csv()
        #expect(csv.contains("foo.pdf,1250mic Libra GCDB,1,750.0,290.0,1,"))
    }

    @Test("Fallback note appears when TrimBox wasn't defined")
    func fallbackNoteAppears() {
        let base = URL(fileURLWithPath: "/x")
        let file = FilePageSizes(
            url: base.appendingPathComponent("a.pdf"),
            pages: [PageSize(pageNumber: 1, widthMm: 100, heightMm: 200, usedFallback: true)],
            totalPages: 1,
            error: nil
        )
        let csv = SizesReport(baseFolder: base, files: [file]).csv()
        #expect(csv.contains("TrimBox not defined, used MediaBox"))
    }

    @Test("Failed file gets one row with the error in Notes and empty dimensions")
    func failedFileEmitsCouldntReadRow() {
        let base = URL(fileURLWithPath: "/x")
        let file = FilePageSizes(
            url: base.appendingPathComponent("oops.pdf"),
            pages: [],
            totalPages: 0,
            error: "PDFKit could not open this file"
        )
        let csv = SizesReport(baseFolder: base, files: [file]).csv()
        // The message contains no `,` `"` or newline so it isn't quoted;
        // RFC 4180 only requires quoting fields with those characters.
        // 7 leading commas = 8 empty/blank fields up to (and not including) the
        // Notes column (filename + 6 empty + Notes).
        #expect(csv.contains("oops.pdf,,,,,,,Couldn't read: PDFKit could not open this file"))
    }

    @Test("Filenames containing commas are quoted")
    func filenameWithCommaIsQuoted() {
        let base = URL(fileURLWithPath: "/x")
        let file = FilePageSizes(
            url: base.appendingPathComponent("Brand A, B & C.pdf"),
            pages: [PageSize(pageNumber: 1, widthMm: 100, heightMm: 100, usedFallback: false)],
            totalPages: 1,
            error: nil
        )
        let csv = SizesReport(baseFolder: base, files: [file]).csv()
        #expect(csv.contains("\"Brand A, B & C.pdf\""))
    }

    @Test("Filenames with embedded quotes have them doubled per RFC 4180")
    func filenameWithQuoteIsEscaped() {
        let base = URL(fileURLWithPath: "/x")
        let file = FilePageSizes(
            url: base.appendingPathComponent("Quoted \"name\".pdf"),
            pages: [PageSize(pageNumber: 1, widthMm: 100, heightMm: 100, usedFallback: false)],
            totalPages: 1,
            error: nil
        )
        let csv = SizesReport(baseFolder: base, files: [file]).csv()
        #expect(csv.contains("\"Quoted \"\"name\"\".pdf\""))
    }

    @Test("Multi-page file renders one row per page")
    func multiPageRendersOneRowPerPage() {
        let base = URL(fileURLWithPath: "/x")
        let pages = (1...3).map { PageSize(pageNumber: $0, widthMm: 210, heightMm: 297, usedFallback: false) }
        let file = FilePageSizes(
            url: base.appendingPathComponent("multi.pdf"),
            pages: pages,
            totalPages: 3,
            error: nil
        )
        let csv = SizesReport(baseFolder: base, files: [file]).csv()
        // Use `components(separatedBy:)` because `String.split(whereSeparator:)`
        // operates on grapheme clusters, and `\r\n` is one grapheme — so a
        // character predicate sees no separators at all in CRLF text.
        let nonEmpty = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(nonEmpty.count == 4) // header + 3 data rows
    }
}

// MARK: - Fixture helper

/// Write a one- or many-page PDF at a unique temp URL with explicit
/// MediaBox/TrimBox, in millimetres for clarity. We round-trip mm → points
/// using the same conversion the production code uses, so any drift in
/// that conversion shows up as a test failure.
private func makeFixture(
    mediaMm: (Double, Double),
    trimMm: (Double, Double)? = nil,
    pageCount: Int = 1
) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("FileShufflerTest-\(UUID().uuidString).pdf")

    let mediaBox = rectFromMm(mediaMm)
    var docMediaBox = mediaBox
    guard let ctx = CGContext(url as CFURL, mediaBox: &docMediaBox, nil) else {
        throw NSError(domain: "PDFTestFixture", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not create PDF context"])
    }

    for _ in 0..<pageCount {
        var info: [CFString: Any] = [
            kCGPDFContextMediaBox: cgRectAsData(mediaBox)
        ]
        if let trim = trimMm {
            info[kCGPDFContextTrimBox] = cgRectAsData(rectFromMm(trim))
        }
        ctx.beginPDFPage(info as CFDictionary)
        ctx.endPDFPage()
    }
    ctx.closePDF()
    return url
}

private func rectFromMm(_ mm: (Double, Double)) -> CGRect {
    let w = mm.0 * 72.0 / 25.4
    let h = mm.1 * 72.0 / 25.4
    return CGRect(x: 0, y: 0, width: w, height: h)
}

private func cgRectAsData(_ rect: CGRect) -> Data {
    var r = rect
    return Data(bytes: &r, count: MemoryLayout<CGRect>.size)
}

/// Compare two doubles to within 0.05 mm. The conversion mm→pts→mm is
/// lossy at the typical floating-point precision; 0.05 is well below the
/// 0.1 mm precision we report in the CSV.
private func approx(_ a: Double, _ b: Double, tolerance: Double = 0.05) -> Bool {
    abs(a - b) <= tolerance
}
