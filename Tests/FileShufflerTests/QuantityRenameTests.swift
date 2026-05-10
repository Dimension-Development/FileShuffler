import Testing
import Foundation
@testable import FileShuffler

@Suite("Quantity rename")
struct QuantityRenameTests {

    // MARK: - Match.destinationFilename

    @Test("No quantity → filename unchanged")
    func noQuantityKeepsFilename() {
        let match = makeMatch(stem: "foo", ext: "ai", quantity: nil)
        #expect(match.destinationFilename == "foo.ai")
        #expect(match.willRename == false)
    }

    @Test("Empty / whitespace quantity → filename unchanged")
    func emptyQuantityKeepsFilename() {
        let m1 = makeMatch(stem: "foo", ext: "ai", quantity: "")
        let m2 = makeMatch(stem: "foo", ext: "ai", quantity: "   ")
        #expect(m1.destinationFilename == "foo.ai")
        #expect(m2.destinationFilename == "foo.ai")
    }

    @Test("Numeric quantity → suffix added before extension")
    func numericQuantityAppendsSuffix() {
        let match = makeMatch(stem: "261144 - Arencia - Shelf liner", ext: "ai", quantity: "30")
        #expect(match.destinationFilename == "261144 - Arencia - Shelf liner_x30.ai")
        #expect(match.willRename)
    }

    @Test("Quantity with surrounding whitespace is trimmed")
    func quantityIsTrimmed() {
        let match = makeMatch(stem: "foo", ext: "ai", quantity: "  100 ")
        #expect(match.destinationFilename == "foo_x100.ai")
    }

    @Test("Filename without an extension still gets the suffix")
    func filenameWithoutExtension() {
        let match = makeMatch(stem: "no-extension", ext: "", quantity: "5")
        #expect(match.destinationFilename == "no-extension_x5")
    }

    // MARK: - SpreadsheetTable

    @Test("Quantity column is auto-detected from common synonyms")
    func quantityColumnAutoDetected() {
        let table = SpreadsheetTable(
            headers: ["File Name", "Folder Name", "Quantity"],
            rows: [["a", "X", "30"]]
        )
        let detected = table.detectColumns()
        #expect(detected.quantity == "Quantity")
    }

    @Test("'Qty' header is also recognised")
    func qtyShorthandIsRecognised() {
        let table = SpreadsheetTable(
            headers: ["File", "Folder", "Qty"],
            rows: [["a", "X", "10"]]
        )
        let detected = table.detectColumns()
        #expect(detected.quantity == "Qty")
    }

    @Test("Quantity flows from row into MappingRow when the column is selected")
    func quantityPassedThroughToMappingRow() throws {
        let table = SpreadsheetTable(
            headers: ["File Name", "Folder Name", "Quantity"],
            rows: [
                ["a", "X", "30"],
                ["b", "Y", ""],     // blank quantity → nil
                ["c", "Z", "100"],
            ]
        )
        let rows = try table.mappingRows(
            fileColumn: "File Name",
            folderColumn: "Folder Name",
            quantityColumn: "Quantity"
        )
        #expect(rows.count == 3)
        #expect(rows[0].quantity == "30")
        #expect(rows[1].quantity == nil)
        #expect(rows[2].quantity == "100")
    }

    @Test("Without a quantity column, MappingRow.quantity is nil")
    func quantityNilWhenColumnNotSelected() throws {
        let table = SpreadsheetTable(
            headers: ["File Name", "Folder Name", "Quantity"],
            rows: [["a", "X", "30"]]
        )
        let rows = try table.mappingRows(
            fileColumn: "File Name",
            folderColumn: "Folder Name",
            quantityColumn: nil
        )
        #expect(rows[0].quantity == nil)
    }

    @Test("Asking for a non-existent quantity column throws")
    func missingQuantityColumnThrows() {
        let table = SpreadsheetTable(
            headers: ["File Name", "Folder Name"],
            rows: [["a", "X"]]
        )
        #expect(throws: SpreadsheetError.self) {
            try table.mappingRows(
                fileColumn: "File Name",
                folderColumn: "Folder Name",
                quantityColumn: "Quantity"
            )
        }
    }

    // MARK: - End-to-end via MoveExecutor

    @Test("Apply with a quantity moves AND renames the file")
    func applyMovesAndRenames() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FileShufflerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let src = base.appendingPathComponent("source/foo.ai")
        try FileManager.default.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: src)

        let match = Match(
            source: SourceFile(url: src, nameStem: "foo", relativePath: "source/foo.ai", baseFolder: base),
            row: MappingRow(id: 0, fileName: "foo", folderName: "Material", quantity: "30"),
            normalised: false
        )
        let result = await MoveExecutor.apply(matches: [match], destinationFolder: base, callbacks: .silent)
        #expect(result.moved.count == 1)

        let renamed = base.appendingPathComponent("Material/foo_x30.ai")
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        #expect(!FileManager.default.fileExists(atPath: src.path))
    }

    // MARK: - helpers

    private func makeMatch(stem: String, ext: String, quantity: String?) -> Match {
        let filename = ext.isEmpty ? stem : "\(stem).\(ext)"
        let url = URL(fileURLWithPath: "/tmp/\(filename)")
        return Match(
            source: SourceFile(url: url, nameStem: stem, relativePath: filename, baseFolder: URL(fileURLWithPath: "/tmp")),
            row: MappingRow(id: 0, fileName: stem, folderName: "X", quantity: quantity),
            normalised: false
        )
    }
}
