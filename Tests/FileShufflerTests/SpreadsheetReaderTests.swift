import Testing
import Foundation
@testable import FileShuffler

/// Tests for the workbook reader against a dummy-data fixture that mirrors
/// the V1 "Print & Laser" job-sheet structure: multiple worksheets, a
/// banner above the real header row (row 9), a table that starts in
/// column B, and rows whose empty cells are simply absent from the file
/// (the XLSX sparse-cell format).
@Suite("SpreadsheetReader — V1 job sheet")
struct SpreadsheetReaderTests {

    private var fixtureURL: URL {
        Bundle.module.url(
            forResource: "jobsheet-v1", withExtension: "xlsx", subdirectory: "Fixtures"
        )!
    }

    @Test("Workbook lists every worksheet in tab order")
    func workbookListsAllSheets() throws {
        let tables = try SpreadsheetReader.readWorkbook(fixtureURL)
        #expect(tables.map(\.name) == ["Cover", "Print & Laser", "CNC"])
    }

    @Test("Best-table pick is the sheet with recognisable job columns")
    func bestTableIsPrintAndLaser() throws {
        let tables = try SpreadsheetReader.readWorkbook(fixtureURL)
        #expect(SpreadsheetReader.bestTable(in: tables)?.name == "Print & Laser")
    }

    @Test("Header row is found beneath the banner rows")
    func headerRowDetectedAtRow9() throws {
        let table = try printAndLaser()
        #expect(table.headers.contains("Artwork name Front"))
        #expect(table.headers.contains("Material"))
        // Banner content must not leak into the table body.
        #expect(!table.rows.contains { $0.contains("JOB SHEET V1") })
        #expect(table.rows.count == 4)
    }

    @Test("Sparse rows keep values under the right headers")
    func sparseCellsStayColumnAligned() throws {
        let table = try printAndLaser()
        // Column B ("Layout") is empty in every data row; without
        // reference-based placement the whole row shifts one column left.
        let headers = table.headers
        let frontIdx = headers.firstIndex(of: "Artwork name Front")!
        let qtyIdx = headers.firstIndex(of: "Qty")!
        let colourIdx = headers.firstIndex(of: "Colour Spec")!
        let first = table.rows[0]
        #expect(first[frontIdx] == "widget-a.pdf")
        #expect(first[colourIdx] == "4/0 - Print to Face - SF")
        #expect(first[qtyIdx] == "16")
    }

    @Test("Column autodetection finds front/back artwork, material, colour spec, qty")
    func detectionFindsJobSheetColumns() throws {
        let detected = try printAndLaser().detectColumns()
        #expect(detected.file == "Artwork name Front")
        #expect(detected.backFile == "Artwork name  Back")   // double space in header
        #expect(detected.folder == "Material")
        #expect(detected.subfolder == "Colour Spec")
        #expect(detected.quantity == "Qty")
    }

    @Test("Mapping rows nest Material/Colour Spec with slashes sanitised")
    func mappingRowsNestAndSanitise() throws {
        let rows = try jobRows()
        let destinations = Set(rows.map(\.folderName))
        #expect(destinations.contains("5mm White Perspex/4-0 - Print to Face - SF"))
        #expect(destinations.contains("5mm White Perspex/0-4 - Reverse - SR"))
        #expect(destinations.contains("3mm Clear Perspex/4-0 - Print to Face - SF"))
    }

    @Test("Per-page duplicate rows collapse into one mapping row")
    func pageRowsDeduplicate() throws {
        let rows = try jobRows()
        let widgetA = rows.filter { $0.fileName == "widget-a.pdf" }
        #expect(widgetA.count == 1)
        #expect(widgetA.first?.quantity == "16")
    }

    @Test("A filled back-artwork cell emits an extra mapping row")
    func backArtworkEmitsExtraRow() throws {
        let rows = try jobRows()
        let backRow = rows.first { $0.fileName == "widget-b-back" }
        #expect(backRow != nil)
        #expect(backRow?.folderName == "5mm White Perspex/0-4 - Reverse - SR")
        #expect(backRow?.quantity == "12")
        // Front and back of the same sheet row keep distinct, stable ids.
        let frontRow = rows.first { $0.fileName == "widget-b" }
        #expect(frontRow != nil)
        #expect(frontRow?.id != backRow?.id)
    }

    @Test("Merged duplicate rows that disagree on quantity drop the quantity")
    func quantityDisagreementDropsQuantity() throws {
        let table = SpreadsheetTable(
            headers: ["File", "Folder", "Qty"],
            rows: [
                ["part.pdf", "Material A", "10"],
                ["part.pdf", "Material A", "12"],
            ]
        )
        let rows = try table.mappingRows(
            fileColumn: "File", folderColumn: "Folder", quantityColumn: "Qty"
        )
        #expect(rows.count == 1)
        #expect(rows.first?.quantity == nil)
    }

    @Test("The banner's artwork server link is captured from the fixture")
    func bannerArtworkLinkCaptured() throws {
        let table = try printAndLaser()
        #expect(table.sourceLinks == [#"\\server\Share\Projects\Test"#])
    }

    @Test("Only link-shaped banner cells are captured, and data rows never are")
    func linkExtractionIsSelective() {
        let table = SpreadsheetTable.from(grid: [
            ["", "JOB SHEET V1"],
            ["Job Name", "Some Client"],                       // plain text — not a link
            ["ARTWORK AT:", "smb://dim-svr/DimensionHub/Projects/X"],
            ["", "/Volumes/DimensionHub/Projects/X"],          // duplicate location, distinct string
            ["File", "Folder"],                                // header row (synonyms)
            ["\\\\not-a-banner\\row", "M1"],                   // below header — data, ignored
        ])
        #expect(table.sourceLinks == [
            "smb://dim-svr/DimensionHub/Projects/X",
            "/Volumes/DimensionHub/Projects/X",
        ])
        #expect(table.rows.count == 1)
    }

    @Test("Workbooks with relationship types CoreXLSX rejects parse via the fallback")
    func unknownRelationshipTypesFallBack() throws {
        // Same fixture with a `sheetMetadata` relationship injected — the
        // exact thing modern Excel writes that makes CoreXLSX's strict
        // relationship enum throw. Real V1 job sheets ship like this.
        let url = Bundle.module.url(
            forResource: "jobsheet-v1-sheetmetadata", withExtension: "xlsx", subdirectory: "Fixtures"
        )!
        let tables = try SpreadsheetReader.readWorkbook(url)
        #expect(tables.map(\.name) == ["Cover", "Print & Laser", "CNC"])
        let best = SpreadsheetReader.bestTable(in: tables)
        #expect(best?.name == "Print & Laser")
        #expect(best?.table.rows.count == 4)
    }

    @Test("Plain headers-in-row-1 sheets still parse unchanged")
    func plainSheetStillWorks() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("FileShufflerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let csv = dir.appendingPathComponent("plain.csv")
        try "My Files,Target\na,M1\nb,M2\n".write(to: csv, atomically: true, encoding: .utf8)

        let table = try SpreadsheetReader.read(csv)
        // Custom header names match no synonyms → fall back to row 1.
        #expect(table.headers == ["My Files", "Target"])
        #expect(table.rows.count == 2)
    }

    @Test("Folder-component sanitisation replaces path-hostile characters")
    func sanitisationReplacesSlashes() {
        #expect(SpreadsheetTable.sanitiseFolderComponent("4/0 - Face") == "4-0 - Face")
        #expect(SpreadsheetTable.sanitiseFolderComponent("a:b") == "a-b")
        #expect(SpreadsheetTable.sanitiseFolderComponent(" plain ") == "plain")
    }

    // MARK: - Sheet-cell extension stripping (MatchEngine.sheetKey)

    @Test("Sheet cells with artwork extensions match extensionless file stems")
    func sheetKeyStripsKnownExtensions() {
        #expect(MatchEngine.sheetKey("Widget-A.pdf") == "widget-a")
        #expect(MatchEngine.sheetKey("shelf riser 738x64mm.AI") == "shelf riser 738x64mm")
        // Dots that aren't artwork extensions survive.
        #expect(MatchEngine.sheetKey("artwork v1.2") == "artwork v1.2")
        #expect(MatchEngine.sheetKey(".pdf") == ".pdf")
    }

    @Test("A .pdf-suffixed sheet cell matches the file on disk end to end")
    func extensionSuffixedCellMatchesFile() {
        let base = URL(fileURLWithPath: "/tmp/x")
        let file = SourceFile(
            url: base.appendingPathComponent("widget-a.pdf"),
            nameStem: "widget-a", relativePath: "widget-a.pdf", baseFolder: base
        )
        let row = MappingRow(id: 0, fileName: "widget-a.pdf", folderName: "M/C")
        let plan = MatchEngine.plan(files: [file], rows: [row])
        #expect(plan.matched.count == 1)
        #expect(plan.sheetRowsWithoutFile.isEmpty)
        #expect(plan.matched.first?.destination == "M/C")
    }

    // MARK: - helpers

    private func printAndLaser() throws -> SpreadsheetTable {
        let tables = try SpreadsheetReader.readWorkbook(fixtureURL)
        return tables.first { $0.name == "Print & Laser" }!.table
    }

    private func jobRows() throws -> [MappingRow] {
        let table = try printAndLaser()
        return try table.mappingRows(
            fileColumn: "Artwork name Front",
            folderColumn: "Material",
            quantityColumn: "Qty",
            backFileColumn: "Artwork name  Back",
            subfolderColumn: "Colour Spec"
        )
    }
}
