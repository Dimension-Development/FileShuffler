import Testing
import Foundation
@testable import FileShuffler

@Suite("ShuffleProject I/O")
struct ShuffleProjectTests {

    @Test("Roundtrip preserves all fields")
    func roundtripPreservesFields() throws {
        let log = makeLog()
        let project = ShuffleProject(
            sourceFolderPaths: [
                "/Users/luke/Desktop/261144 - Cerave",
                "/Users/luke/Desktop/261144 - Better You"
            ],
            destinationPath: "/Users/luke/Desktop/261144 - Output",
            sheetPath: "/Users/luke/Desktop/261144.xlsx",
            fileColumn: "File Name",
            folderColumn: "Folder Name",
            quantityColumn: "Quantity",
            conflictResolutions: [
                "7": ResolutionRecord(kind: "use", chosenPath: "/Users/luke/Desktop/261144 - Cerave/dupe.ai"),
                "9": ResolutionRecord(kind: "skip", chosenPath: nil),
            ],
            auditLog: log,
            savedAt: Date(timeIntervalSince1970: 1_715_000_000)
        )

        let dir = tempdir()
        let url = dir.appendingPathComponent("job.shuffle")
        try ShuffleProjectIO.save(project, to: url)
        let loaded = try ShuffleProjectIO.load(from: url)

        #expect(loaded == project)
    }

    @Test("Project with no quantity column roundtrips")
    func roundtripWithoutQuantity() throws {
        let project = ShuffleProject(
            sourceFolderPaths: ["/x"],
            destinationPath: "/x",
            sheetPath: "/y.xlsx",
            fileColumn: "File Name",
            folderColumn: "Folder Name",
            quantityColumn: nil
        )
        let dir = tempdir()
        let url = dir.appendingPathComponent("a.shuffle")
        try ShuffleProjectIO.save(project, to: url)
        let loaded = try ShuffleProjectIO.load(from: url)
        #expect(loaded.quantityColumn == nil)
    }

    @Test("v1 project file is read as v2: single base promoted to one source + same destination")
    func v1FileBackwardsCompat() throws {
        // Hand-written v1 JSON — what the previous build saved. The v2 reader
        // must accept it without error and promote `baseFolderPath` to a
        // one-element sources list with destination matching.
        let json = """
        {
          "version": 1,
          "baseFolderPath": "/Users/luke/Desktop/261144",
          "sheetPath": "/Users/luke/Desktop/261144.xlsx",
          "fileColumn": "File Name",
          "folderColumn": "Folder Name",
          "quantityColumn": "Quantity",
          "savedAt": "2026-04-09T12:00:00Z"
        }
        """
        let dir = tempdir()
        let url = dir.appendingPathComponent("v1.shuffle")
        try Data(json.utf8).write(to: url)

        let loaded = try ShuffleProjectIO.load(from: url)
        #expect(loaded.version == 1)
        #expect(loaded.sourceFolderPaths == ["/Users/luke/Desktop/261144"])
        #expect(loaded.destinationPath == "/Users/luke/Desktop/261144")
        #expect(loaded.fileColumn == "File Name")
        #expect(loaded.folderColumn == "Folder Name")
        #expect(loaded.quantityColumn == "Quantity")
        #expect(loaded.conflictResolutions.isEmpty)
    }

    @Test("Decoding a future-version file throws unsupportedVersion")
    func futureVersionRejected() throws {
        let json = """
        {
          "version": 999,
          "sourceFolderPaths": ["/a"],
          "destinationPath": "/a",
          "sheetPath": "/b",
          "fileColumn": "File",
          "folderColumn": "Folder",
          "savedAt": "2026-05-09T12:00:00Z"
        }
        """
        let dir = tempdir()
        let url = dir.appendingPathComponent("future.shuffle")
        try Data(json.utf8).write(to: url)

        #expect(throws: ProjectIOError.self) {
            try ShuffleProjectIO.load(from: url)
        }
    }

    // MARK: helpers

    private func tempdir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("FileShufflerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeLog() -> AuditLog {
        AuditLog(
            startedAt: Date(timeIntervalSince1970: 1_715_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_715_000_010),
            operatorName: "Luke Atkins",
            sourceFolderPaths: ["/Users/luke/Desktop/261144 - Cerave"],
            destinationPath: "/Users/luke/Desktop/261144 - Output",
            sheetPath: "/Users/luke/Desktop/261144.xlsx",
            moves: [
                LoggedMove(src: "/a/b.ai", dst: "/c/b_x30.ai")
            ],
            skipped: ["src/skipped.ai"],
            errors: [LoggedError(src: "/a/oops.ai", message: "Permission denied")],
            stoppedEarly: false
        )
    }
}

@Suite("AuditLog text export")
struct AuditLogReportTests {

    @Test("Report includes summary and every move")
    func reportContainsSummaryAndMoves() {
        let log = AuditLog(
            startedAt: Date(timeIntervalSince1970: 1_715_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_715_000_005),
            operatorName: "Luke",
            sourceFolderPaths: ["/base"],
            destinationPath: "/base",
            sheetPath: "/base/sheet.xlsx",
            moves: [
                LoggedMove(src: "/base/src/a.ai", dst: "/base/M/a_x30.ai"),
                LoggedMove(src: "/base/src/b.ai", dst: "/base/M/b.ai"),
            ],
            skipped: [],
            errors: [],
            stoppedEarly: false
        )
        let text = log.plainTextReport()
        #expect(text.contains("Operator:    Luke"))
        #expect(text.contains("Moved:   2"))
        #expect(text.contains("Skipped: 0"))
        #expect(text.contains("Errors:  0"))
        #expect(text.contains("/base/src/a.ai"))
        #expect(text.contains("/base/M/a_x30.ai"))
        #expect(text.contains("/base/src/b.ai"))
    }

    @Test("Copy-mode report says Copied / Copies; legacy logs stay Moved / Moves")
    func reportUsesCopyWording() {
        var log = AuditLog(
            startedAt: Date(timeIntervalSince1970: 1_715_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_715_000_005),
            operatorName: "Luke",
            sourceFolderPaths: ["/base"],
            destinationPath: "/base",
            sheetPath: "",
            moves: [LoggedMove(src: "/base/src/a.ai", dst: "/base/M/a.ai")],
            skipped: [],
            errors: [],
            stoppedEarly: false,
            transferMode: "copy"
        )
        let copyText = log.plainTextReport()
        #expect(copyText.contains("Copied:  1"))
        #expect(copyText.contains("Copies:"))
        #expect(!copyText.contains("Moved:"))

        // A log without a recorded mode predates the copy behaviour — it
        // was a move, and the report must keep saying so.
        log.transferMode = nil
        let legacyText = log.plainTextReport()
        #expect(legacyText.contains("Moved:   1"))
        #expect(legacyText.contains("Moves:"))
    }

    @Test("Report flags cancelled apply")
    func reportFlagsCancellation() {
        let log = AuditLog(
            startedAt: Date(),
            finishedAt: Date(),
            operatorName: "Luke",
            sourceFolderPaths: ["/x"],
            destinationPath: "/x",
            sheetPath: "",
            moves: [],
            skipped: [],
            errors: [],
            stoppedEarly: true
        )
        #expect(log.plainTextReport().contains("cancelled"))
    }

    @Test("Report omits sheet line when sheet path is empty")
    func reportOmitsSheetWhenEmpty() {
        let log = AuditLog(
            startedAt: Date(),
            finishedAt: Date(),
            operatorName: "Luke",
            sourceFolderPaths: ["/x"],
            destinationPath: "/x",
            sheetPath: "",
            moves: [],
            skipped: [],
            errors: [],
            stoppedEarly: false
        )
        #expect(!log.plainTextReport().contains("Spreadsheet:"))
    }

    @Test("Multi-source report lists every source under a Sources header")
    func multiSourceReportListsAllSources() {
        let log = AuditLog(
            startedAt: Date(),
            finishedAt: Date(),
            operatorName: "Luke",
            sourceFolderPaths: ["/a", "/b", "/c"],
            destinationPath: "/dest",
            sheetPath: "/sheet.xlsx",
            moves: [],
            skipped: [],
            errors: [],
            stoppedEarly: false
        )
        let text = log.plainTextReport()
        #expect(text.contains("Sources:"))
        #expect(text.contains("  /a"))
        #expect(text.contains("  /b"))
        #expect(text.contains("  /c"))
        #expect(text.contains("Destination: /dest"))
    }

    @Test("Single-source report uses singular 'Source:' label")
    func singleSourceReportUsesSingularLabel() {
        let log = AuditLog(
            startedAt: Date(),
            finishedAt: Date(),
            operatorName: "Luke",
            sourceFolderPaths: ["/just-one"],
            destinationPath: "/dest",
            sheetPath: "",
            moves: [],
            skipped: [],
            errors: [],
            stoppedEarly: false
        )
        let text = log.plainTextReport()
        #expect(text.contains("Source:      /just-one"))
        #expect(!text.contains("Sources:\n"))
    }
}
