import Testing
import Foundation
@testable import FileShuffler

/// Tests for the two-pass matcher and the conditional rename behaviour
/// that together make the Quantity feature idempotent: re-running on
/// already-renamed files works correctly, while files that legitimately
/// contain a `_xN` suffix in their original name aren't silently rewritten.
@Suite("Idempotent matching + rename")
struct IdempotentRenameTests {

    // MARK: - stripQuantitySuffix

    @Test("Strip helper removes a trailing _xN")
    func stripRemovesTrailingSuffix() {
        #expect(MatchEngine.stripQuantitySuffix("widget_x12") == "widget")
        #expect(MatchEngine.stripQuantitySuffix("foo_x100") == "foo")
    }

    @Test("Strip helper is case-insensitive on the x")
    func stripIsCaseInsensitive() {
        #expect(MatchEngine.stripQuantitySuffix("widget_X12") == "widget")
    }

    @Test("Strip helper leaves names without a trailing _xN alone")
    func stripPreservesNonMatching() {
        #expect(MatchEngine.stripQuantitySuffix("plain") == "plain")
        // _xN in the middle, not the end, must be preserved
        #expect(MatchEngine.stripQuantitySuffix("foo_x12_more") == "foo_x12_more")
        // Non-digit suffix isn't a quantity
        #expect(MatchEngine.stripQuantitySuffix("foo_xyz") == "foo_xyz")
    }

    @Test("Strip helper refuses to return an empty string")
    func stripRefusesToReturnEmpty() {
        // A stem of just `_x12` would strip to empty and falsely match any
        // other empty-stem file; the helper preserves the original instead.
        #expect(MatchEngine.stripQuantitySuffix("_x12") == "_x12")
    }

    // MARK: - Pass 1 (exact match) — preserves legitimate _xN

    @Test("Legitimate _xN filename matches its sheet row exactly (Pass 1)")
    func legitSuffixMatchesExactlyInPass1() {
        let files = [makeFile("widget_x12")]
        let rows = [MappingRow(id: 0, fileName: "widget_x12", folderName: "X")]
        let plan = MatchEngine.plan(files: files, rows: rows)

        #expect(plan.matched.count == 1)
        let m = try! #require(plan.matched.first)
        #expect(m.stemMatchedAfterStrip == false)
        #expect(m.normalised == false)
    }

    // MARK: - Pass 2 (stripped match) — catches re-run files

    @Test("Already-renamed file matches the bare sheet row via Pass 2")
    func renamedFileMatchesBareRowInPass2() {
        // Real fixture from TEST 2: file already has `_x12` baked in,
        // sheet has the original name.
        let files = [makeFile("261144 - Arencia - Please Retain Sticker - 60mm x 12mm_x12")]
        let rows = [MappingRow(
            id: 0,
            fileName: "261144 - Arencia - Please Retain Sticker - 60mm x 12mm",
            folderName: "Orajet SAV"
        )]
        let plan = MatchEngine.plan(files: files, rows: rows)

        #expect(plan.matched.count == 1)
        let m = try! #require(plan.matched.first)
        #expect(m.stemMatchedAfterStrip == true)
        // Pass-2 matches always set normalised so the UI shows ⚠.
        #expect(m.normalised == true)
    }

    // MARK: - Two-pass priority

    @Test("Both an exact match and a stripped candidate present — exact wins")
    func exactWinsOverStrippedWhenBothPresent() {
        // Sheet asks for `widget`. Disk has both `widget` and `widget_x12`.
        // Pass 1 matches `widget` exactly. `widget_x12` should fall to
        // "Files not in sheet", NOT be hijacked by a stripped match.
        let files = [makeFile("widget"), makeFile("widget_x12")]
        let rows = [MappingRow(id: 0, fileName: "widget", folderName: "X")]
        let plan = MatchEngine.plan(files: files, rows: rows)

        #expect(plan.matched.count == 1)
        #expect(plan.matched.first?.source.nameStem == "widget")
        #expect(plan.matched.first?.stemMatchedAfterStrip == false)
        #expect(plan.filesNotInSheet.count == 1)
        #expect(plan.filesNotInSheet.first?.nameStem == "widget_x12")
    }

    @Test("Sheet has both bare and suffixed rows; both files present — each matches exactly")
    func bothRowsAndBothFilesAllExactMatches() {
        let files = [makeFile("widget"), makeFile("widget_x12")]
        let rows = [
            MappingRow(id: 0, fileName: "widget", folderName: "A"),
            MappingRow(id: 1, fileName: "widget_x12", folderName: "B"),
        ]
        let plan = MatchEngine.plan(files: files, rows: rows)

        #expect(plan.matched.count == 2)
        #expect(plan.matched.allSatisfy { $0.stemMatchedAfterStrip == false })
        #expect(plan.sheetRowsWithoutFile.isEmpty)
        #expect(plan.filesNotInSheet.isEmpty)
    }

    // MARK: - destinationFilename — replace vs stack

    @Test("Pass-1 match (exact) with a quantity stacks a new _xN — preserves user data")
    func exactMatchWithQuantityStacksSuffix() {
        let m = makeMatch(
            stem: "widget_x12",
            ext: "pdf",
            quantity: "5",
            stemMatchedAfterStrip: false
        )
        #expect(m.destinationFilename == "widget_x12_x5.pdf")
        #expect(m.willRename)
    }

    @Test("Pass-2 match (stripped) with a quantity replaces the existing _xN")
    func strippedMatchWithQuantityReplacesSuffix() {
        let m = makeMatch(
            stem: "widget_x12",
            ext: "pdf",
            quantity: "24",
            stemMatchedAfterStrip: true
        )
        #expect(m.destinationFilename == "widget_x24.pdf")
    }

    @Test("Pass-2 match with the same quantity is a no-op rename")
    func strippedMatchWithSameQuantityIsNoOp() {
        let m = makeMatch(
            stem: "widget_x12",
            ext: "pdf",
            quantity: "12",
            stemMatchedAfterStrip: true
        )
        #expect(m.destinationFilename == "widget_x12.pdf")
        #expect(m.willRename == false)
    }

    @Test("Pass-2 match with no quantity column moves the file but preserves the existing _xN")
    func strippedMatchWithNoQuantityPreservesSuffix() {
        // Quantity column not selected for this row → row.quantity is nil.
        // We still moved the file in Pass 2 (matched after stripping), but
        // the destination filename is unchanged from the source — we never
        // strip a suffix unless we're also adding one.
        let m = makeMatch(
            stem: "widget_x12",
            ext: "pdf",
            quantity: nil,
            stemMatchedAfterStrip: true
        )
        #expect(m.destinationFilename == "widget_x12.pdf")
        #expect(m.willRename == false)
    }

    // MARK: - Helpers

    private func makeFile(_ stem: String) -> SourceFile {
        SourceFile(
            url: URL(fileURLWithPath: "/tmp/\(stem).pdf"),
            nameStem: stem,
            relativePath: "\(stem).pdf"
        )
    }

    private func makeMatch(
        stem: String,
        ext: String,
        quantity: String?,
        stemMatchedAfterStrip: Bool
    ) -> Match {
        let filename = ext.isEmpty ? stem : "\(stem).\(ext)"
        let url = URL(fileURLWithPath: "/tmp/\(filename)")
        return Match(
            source: SourceFile(url: url, nameStem: stem, relativePath: filename),
            row: MappingRow(id: 0, fileName: stem, folderName: "X", quantity: quantity),
            normalised: stemMatchedAfterStrip,
            stemMatchedAfterStrip: stemMatchedAfterStrip
        )
    }
}
