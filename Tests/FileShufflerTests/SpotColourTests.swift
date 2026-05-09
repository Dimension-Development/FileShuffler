import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import FileShuffler

/// Tests for spot-colour extraction.
///
/// Fixtures are tiny hand-written PDFs whose `/Resources/ColorSpace`
/// dictionaries declare `Separation` colour spaces with named tint
/// functions. We synthesise the bytes directly rather than driving
/// `CGContext` because CoreGraphics doesn't expose a Swift API for
/// `CGColorSpaceCreateSeparation` — and the bytes are short, deterministic,
/// and well-commented.
@Suite("SpotColourExtractor")
struct SpotColourExtractorTests {

    @Test("CMYK-only pages return no spots")
    func cmykOnlyHasNoSpots() throws {
        let url = try makeFixturePDF(spots: [])
        defer { try? FileManager.default.removeItem(at: url) }

        let spots = try extractSpots(from: url)
        #expect(spots == [])
    }

    @Test("A single Pantone separation is reported verbatim")
    func singleSpotIsExtracted() throws {
        let url = try makeFixturePDF(spots: ["PANTONE 185 C"])
        defer { try? FileManager.default.removeItem(at: url) }

        let spots = try extractSpots(from: url)
        #expect(spots == ["PANTONE 185 C"])
    }

    @Test("Multiple separations are reported alphabetised and deduped")
    func multipleSpotsAreReportedSorted() throws {
        // Deliberately out of order, with a duplicate, to exercise both.
        let url = try makeFixturePDF(spots: [
            "PANTONE Reflex Blue",
            "Cutter",
            "PANTONE 185 C",
            "Cutter"
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let spots = try extractSpots(from: url)
        #expect(spots == ["Cutter", "PANTONE 185 C", "PANTONE Reflex Blue"])
    }

    @Test("Process colorant names mistakenly used as separation names are filtered")
    func processNamesAreFiltered() throws {
        // Some files embed standalone Black or Cyan as Separation spaces;
        // those aren't real spots and shouldn't appear in the report.
        let url = try makeFixturePDF(spots: ["Black", "Cyan", "PANTONE 185 C"])
        defer { try? FileManager.default.removeItem(at: url) }

        let spots = try extractSpots(from: url)
        #expect(spots == ["PANTONE 185 C"])
    }

    @Test("/All separation (used for crop marks) is filtered")
    func allSeparationIsFiltered() throws {
        let url = try makeFixturePDF(spots: ["All", "PANTONE 185 C"])
        defer { try? FileManager.default.removeItem(at: url) }

        let spots = try extractSpots(from: url)
        #expect(spots == ["PANTONE 185 C"])
    }

    @Test("Spot colour declared in a Form XObject is found by recursion")
    func spotInFormXObjectIsFoundByRecursion() throws {
        // Hand-built PDF: page declares no spots, but places a Form XObject
        // that does. The extractor should descend and find it.
        let url = try makeXObjectFixture(
            pageSpots: [],
            xobjectSpots: ["Cutter"]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let spots = try extractSpots(from: url)
        #expect(spots == ["Cutter"])
    }

    @Test("Page-level and XObject-level spots are merged and deduped")
    func pageAndXObjectSpotsMerge() throws {
        let url = try makeXObjectFixture(
            pageSpots: ["PANTONE 185 C"],
            xobjectSpots: ["Cutter", "PANTONE 185 C"]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let spots = try extractSpots(from: url)
        #expect(spots == ["Cutter", "PANTONE 185 C"])
    }

    // MARK: helpers

    private func extractSpots(from url: URL) throws -> [String] {
        let pdf = try #require(PDFDocument(url: url))
        let page = try #require(pdf.page(at: 0))
        return SpotColourExtractor.spotColours(in: page)
    }
}

@Suite("SpotColourExtractor — CSV integration")
struct SpotColourCSVTests {

    @Test("Spot colours appear in the report column, semicolon-separated")
    func spotColumnIsPopulated() {
        let base = URL(fileURLWithPath: "/x")
        let file = FilePageSizes(
            url: base.appendingPathComponent("a.pdf"),
            pages: [PageSize(
                pageNumber: 1, widthMm: 210, heightMm: 297,
                usedFallback: false,
                spotColours: ["Cutter", "PANTONE 185 C"]
            )],
            totalPages: 1,
            error: nil
        )
        let csv = SizesReport(baseFolder: base, files: [file]).csv()
        #expect(csv.contains("a.pdf,,1,210.0,297.0,1,Cutter; PANTONE 185 C,"))
    }

    @Test("Pages with no spots leave the cell empty")
    func emptyWhenNoSpots() {
        let base = URL(fileURLWithPath: "/x")
        let file = FilePageSizes(
            url: base.appendingPathComponent("a.pdf"),
            pages: [PageSize(
                pageNumber: 1, widthMm: 210, heightMm: 297,
                usedFallback: false,
                spotColours: []
            )],
            totalPages: 1,
            error: nil
        )
        let csv = SizesReport(baseFolder: base, files: [file]).csv()
        // Two adjacent commas before the trailing newline = empty Spot
        // colours field followed by empty Notes field.
        #expect(csv.contains("a.pdf,,1,210.0,297.0,1,,"))
    }
}

// MARK: - Fixture helpers (hand-written minimal PDFs)

/// Page-level only: build a PDF whose page declares each name in `spots`
/// as a `Separation` colour space in `/Resources/ColorSpace`.
private func makeFixturePDF(spots: [String]) throws -> URL {
    return try makeXObjectFixture(pageSpots: spots, xobjectSpots: [])
}

/// Build a tiny PDF where the page resources declare `pageSpots`, and the
/// page references a Form XObject whose own resources declare
/// `xobjectSpots`. The bytes here are minimal but valid — verified by
/// PDFKit accepting them in the tests above.
private func makeXObjectFixture(
    pageSpots: [String],
    xobjectSpots: [String]
) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("FileShufflerSpotTest-\(UUID().uuidString).pdf")

    var data = Data()
    var offsets: [Int] = []
    func emit(_ s: String) {
        data.append(s.data(using: .utf8)!)
    }
    func startObject(_ id: Int) {
        offsets.append(data.count)
        emit("\(id) 0 obj\n")
    }
    func endObject() { emit("endobj\n") }

    emit("%PDF-1.4\n")
    emit("%âãÏÓ\n")  // 4 high-bit bytes — flags the file as binary-safe to readers

    let needsXObject = !xobjectSpots.isEmpty
    // Object IDs:
    //   1: Catalog
    //   2: Pages
    //   3: Page
    //   4: Form XObject (only when needsXObject)
    //   then: tint function objects, one per declared spot
    var nextID = needsXObject ? 5 : 4
    let pageTintIDs: [Int] = pageSpots.map { _ in let id = nextID; nextID += 1; return id }
    let xoTintIDs:   [Int] = xobjectSpots.map { _ in let id = nextID; nextID += 1; return id }

    func colorSpaceDictBody(spots: [String], tintIDs: [Int]) -> String {
        var out = ""
        for (i, name) in spots.enumerated() {
            out += "/CS\(i) [/Separation /\(escapePDFName(name)) /DeviceCMYK \(tintIDs[i]) 0 R] "
        }
        return out
    }

    // Catalog
    startObject(1)
    emit("<< /Type /Catalog /Pages 2 0 R >>\n")
    endObject()

    // Pages
    startObject(2)
    emit("<< /Type /Pages /Kids [3 0 R] /Count 1 >>\n")
    endObject()

    // Page
    startObject(3)
    emit("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842]")
    emit(" /Resources << ")
    emit("/ColorSpace << \(colorSpaceDictBody(spots: pageSpots, tintIDs: pageTintIDs)) >> ")
    if needsXObject {
        emit("/XObject << /Form0 4 0 R >> ")
    }
    emit(">> >>\n")
    endObject()

    // Form XObject (only when there's something to declare in it)
    if needsXObject {
        startObject(4)
        emit("<< /Type /XObject /Subtype /Form /BBox [0 0 100 100]")
        emit(" /Resources << ")
        emit("/ColorSpace << \(colorSpaceDictBody(spots: xobjectSpots, tintIDs: xoTintIDs)) >> ")
        emit(">> /Length 0 >>\nstream\n\nendstream\n")
        endObject()
    }

    // Tint functions: a tiny linear ramp for each declared spot
    for id in pageTintIDs + xoTintIDs {
        startObject(id)
        emit("<< /FunctionType 2 /Domain [0 1] /C0 [0 0 0 0] /C1 [1 1 1 1] /N 1 >>\n")
        endObject()
    }

    // xref + trailer
    let xrefOffset = data.count
    let totalObjects = offsets.count + 1   // +1 for the implicit free object 0
    emit("xref\n0 \(totalObjects)\n")
    emit("0000000000 65535 f \n")
    for off in offsets {
        emit(String(format: "%010d 00000 n \n", off))
    }
    emit("trailer\n<< /Size \(totalObjects) /Root 1 0 R >>\n")
    emit("startxref\n\(xrefOffset)\n")
    emit("%%EOF\n")

    try data.write(to: url)
    return url
}

/// Escape a string into a PDF Name token. Spaces and any byte outside the
/// safe printable range get hex-encoded with the `#XX` escape.
private func escapePDFName(_ s: String) -> String {
    var out = ""
    for byte in s.utf8 {
        let safe = (byte > 0x20 && byte < 0x7F)
            && byte != UInt8(ascii: "#")
            && byte != UInt8(ascii: "(") && byte != UInt8(ascii: ")")
            && byte != UInt8(ascii: "<") && byte != UInt8(ascii: ">")
            && byte != UInt8(ascii: "[") && byte != UInt8(ascii: "]")
            && byte != UInt8(ascii: "{") && byte != UInt8(ascii: "}")
            && byte != UInt8(ascii: "/") && byte != UInt8(ascii: "%")
        if safe {
            out.append(Character(UnicodeScalar(byte)))
        } else {
            out.append(String(format: "#%02X", byte))
        }
    }
    return out
}
