import Testing
import Foundation
@testable import FileShuffler

@Suite("MatchEngine")
struct MatchEngineTests {

    @Test("Normalisation collapses repeated whitespace")
    func normaliseCollapsesDoubleSpace() {
        #expect(
            MatchEngine.normalise("261144 -  By Ellie - A&I graphic 150mm x160mm")
                == MatchEngine.normalise("261144 - By Ellie - A&I graphic 150mm x160mm")
        )
    }

    @Test("Normalisation lowercases")
    func normaliseLowercases() {
        #expect(MatchEngine.normalise("FOO bar") == MatchEngine.normalise("foo BAR"))
    }

    @Test("Normalisation trims and collapses")
    func normaliseTrimsAndCollapses() {
        #expect(MatchEngine.normalise("  hello   world  ") == "hello world")
    }

    /// Real fixture from job 261144: the Arencia A&I graphic was missing
    /// from the spreadsheet, and the Shelf liner row had two spaces after
    /// the dash. Both behaviours must be exposed by the plan.
    @Test("Plan against real-job fixture surfaces orphan and matches normalised file")
    func planWithRealJobFixture() {
        let files = [
            file("261144 -  Arencia- Shelf liner  - 750x290mm"),
            file("261144 -  Arencia - A&I graphic 150mm x160mm"),  // not in sheet
        ]
        let rows = [
            MappingRow(id: 0,
                       fileName: "261144 -  Arencia- Shelf liner  - 750x290mm",
                       folderName: "1250mic Libra GCDB"),
            MappingRow(id: 1,
                       fileName: "Some Missing File",
                       folderName: "Anywhere"),
        ]
        let plan = MatchEngine.plan(files: files, rows: rows)

        #expect(plan.matched.count == 1)
        #expect(plan.matched.first?.destination == "1250mic Libra GCDB")
        #expect(plan.sheetRowsWithoutFile.count == 1)
        #expect(plan.sheetRowsWithoutFile.first?.fileName == "Some Missing File")
        #expect(plan.filesNotInSheet.count == 1)
        #expect(plan.filesNotInSheet.first?.nameStem == "261144 -  Arencia - A&I graphic 150mm x160mm")
    }

    @Test("Match that needed normalisation is flagged for spot-check")
    func normalisedMatchIsFlagged() {
        let files = [file("261144 -  By Ellie - Tray Strips 725mm x 38mm")]
        let rows = [MappingRow(id: 0,
                               fileName: "261144 - By Ellie - Tray Strips 725mm x 38mm",
                               folderName: "Dtec Tearproof")]
        let plan = MatchEngine.plan(files: files, rows: rows)
        #expect(plan.matched.count == 1)
        #expect(plan.matched.first?.normalised == true)
    }

    @Test("Duplicate filenames in different folders surface second as orphan")
    func duplicateFileNamesSurfaceSecondAsOrphan() {
        let files = [
            file("dupe", at: "/tmp/folder-a/dupe.ai"),
            file("dupe", at: "/tmp/folder-b/dupe.ai"),
        ]
        let rows = [MappingRow(id: 0, fileName: "dupe", folderName: "X")]
        let plan = MatchEngine.plan(files: files, rows: rows)
        #expect(plan.matched.count == 1)
        #expect(plan.filesNotInSheet.count == 1)
    }

    // MARK: helpers

    private func file(_ stem: String, at path: String? = nil) -> SourceFile {
        let url = URL(fileURLWithPath: path ?? "/tmp/\(stem).ai")
        return SourceFile(url: url, nameStem: stem, relativePath: "\(stem).ai")
    }
}
