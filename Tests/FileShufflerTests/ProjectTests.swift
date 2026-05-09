import Testing
import Foundation
@testable import FileShuffler

@Suite("ShuffleProject I/O")
struct ShuffleProjectTests {

    @Test("Roundtrip preserves all fields")
    func roundtripPreservesFields() throws {
        let log = makeLog()
        let project = ShuffleProject(
            baseFolderPath: "/Users/luke/Desktop/261144",
            sheetPath: "/Users/luke/Desktop/261144.xlsx",
            fileColumn: "File Name",
            folderColumn: "Folder Name",
            quantityColumn: "Quantity",
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
            baseFolderPath: "/x",
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

    @Test("Decoding a future-version file throws unsupportedVersion")
    func futureVersionRejected() throws {
        let json = """
        {
          "version": 999,
          "baseFolderPath": "/a",
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
            baseFolderPath: "/Users/luke/Desktop/261144",
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
            baseFolderPath: "/base",
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

    @Test("Report flags cancelled apply")
    func reportFlagsCancellation() {
        let log = AuditLog(
            startedAt: Date(),
            finishedAt: Date(),
            operatorName: "Luke",
            baseFolderPath: "/x",
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
            baseFolderPath: "/x",
            sheetPath: "",
            moves: [],
            skipped: [],
            errors: [],
            stoppedEarly: false
        )
        #expect(!log.plainTextReport().contains("Spreadsheet:"))
    }
}
