import Testing
import Foundation
@testable import FileShuffler

/// Real-filesystem tests for the move/undo engine. Each test stands up its
/// own tempdir under `NSTemporaryDirectory()` and tears it down on exit, so
/// runs are independent and can execute in parallel.
@Suite("MoveExecutor")
struct MoveExecutorTests {

    @Test("Apply moves matched files into destination subfolders")
    func applyMovesFiles() async throws {
        try await withTempBase { base in
            let src = try makeFile(at: base.appendingPathComponent("source/a.ai"))
            let match = Match(
                source: SourceFile(url: src, nameStem: "a", relativePath: "source/a.ai", baseFolder: base),
                row: MappingRow(id: 0, fileName: "a", folderName: "Material One"),
                normalised: false
            )
            let result = await MoveExecutor.apply(
                matches: [match], destinationFolder: base, mode: .move, callbacks: .silent
            )
            #expect(result.moved.count == 1)
            #expect(result.errors.isEmpty)
            let dst = base.appendingPathComponent("Material One/a.ai")
            #expect(FileManager.default.fileExists(atPath: dst.path))
            #expect(!FileManager.default.fileExists(atPath: src.path))
        }
    }

    @Test("Collision prompts and Skip leaves the existing destination alone")
    func collisionSkipKeepsExisting() async throws {
        try await withTempBase { base in
            let src = try makeFile(at: base.appendingPathComponent("source/a.ai"), contents: "new")
            let dst = try makeFile(at: base.appendingPathComponent("Material One/a.ai"), contents: "existing")
            let match = Match(
                source: SourceFile(url: src, nameStem: "a", relativePath: "source/a.ai", baseFolder: base),
                row: MappingRow(id: 0, fileName: "a", folderName: "Material One"),
                normalised: false
            )
            let callbacks = MoveExecutorCallbacks(
                onProgress: { _ in },
                onCollision: { _, _ in .skip(forAll: false) }
            )
            let result = await MoveExecutor.apply(
                matches: [match], destinationFolder: base, mode: .move, callbacks: callbacks
            )
            #expect(result.moved.isEmpty)
            #expect(result.skipped.count == 1)
            // Existing file untouched
            let kept = try String(contentsOf: dst, encoding: .utf8)
            #expect(kept == "existing")
            // Source file untouched
            #expect(FileManager.default.fileExists(atPath: src.path))
        }
    }

    @Test("Collision Replace overwrites and counts as a move")
    func collisionReplaceOverwrites() async throws {
        try await withTempBase { base in
            let src = try makeFile(at: base.appendingPathComponent("source/a.ai"), contents: "new")
            let dst = try makeFile(at: base.appendingPathComponent("Material One/a.ai"), contents: "existing")
            let match = Match(
                source: SourceFile(url: src, nameStem: "a", relativePath: "source/a.ai", baseFolder: base),
                row: MappingRow(id: 0, fileName: "a", folderName: "Material One"),
                normalised: false
            )
            let callbacks = MoveExecutorCallbacks(
                onProgress: { _ in },
                onCollision: { _, _ in .replace(forAll: false) }
            )
            let result = await MoveExecutor.apply(
                matches: [match], destinationFolder: base, mode: .move, callbacks: callbacks
            )
            #expect(result.moved.count == 1)
            let final = try String(contentsOf: dst, encoding: .utf8)
            #expect(final == "new")
        }
    }

    @Test("Sticky 'replace all' decision applies to subsequent collisions")
    func stickyReplaceAll() async throws {
        try await withTempBase { base in
            // Two sources that collide with two existing destinations
            let s1 = try makeFile(at: base.appendingPathComponent("src/a.ai"), contents: "newA")
            let s2 = try makeFile(at: base.appendingPathComponent("src/b.ai"), contents: "newB")
            _ = try makeFile(at: base.appendingPathComponent("M/a.ai"), contents: "oldA")
            _ = try makeFile(at: base.appendingPathComponent("M/b.ai"), contents: "oldB")

            let matches = [
                Match(source: SourceFile(url: s1, nameStem: "a", relativePath: "src/a.ai", baseFolder: base),
                      row: MappingRow(id: 0, fileName: "a", folderName: "M"), normalised: false),
                Match(source: SourceFile(url: s2, nameStem: "b", relativePath: "src/b.ai", baseFolder: base),
                      row: MappingRow(id: 1, fileName: "b", folderName: "M"), normalised: false),
            ]
            // Counter so we can assert we were only asked once.
            actor Counter { var n = 0; func bump() { n += 1 } }
            let counter = Counter()
            let callbacks = MoveExecutorCallbacks(
                onProgress: { _ in },
                onCollision: { _, _ in
                    await counter.bump()
                    return .replace(forAll: true)
                }
            )
            let result = await MoveExecutor.apply(
                matches: matches, destinationFolder: base, mode: .move, callbacks: callbacks
            )
            #expect(result.moved.count == 2)
            await #expect(counter.n == 1, "executor should only prompt once when policy goes sticky")
        }
    }

    @Test("Cancel stops the apply and reports stoppedEarly")
    func cancelStopsApply() async throws {
        try await withTempBase { base in
            let s1 = try makeFile(at: base.appendingPathComponent("src/a.ai"))
            _ = try makeFile(at: base.appendingPathComponent("M/a.ai"))   // collide
            let s2 = try makeFile(at: base.appendingPathComponent("src/b.ai"))

            let matches = [
                Match(source: SourceFile(url: s1, nameStem: "a", relativePath: "src/a.ai", baseFolder: base),
                      row: MappingRow(id: 0, fileName: "a", folderName: "M"), normalised: false),
                Match(source: SourceFile(url: s2, nameStem: "b", relativePath: "src/b.ai", baseFolder: base),
                      row: MappingRow(id: 1, fileName: "b", folderName: "M"), normalised: false),
            ]
            let callbacks = MoveExecutorCallbacks(
                onProgress: { _ in },
                onCollision: { _, _ in .cancel }
            )
            let result = await MoveExecutor.apply(
                matches: matches, destinationFolder: base, mode: .move, callbacks: callbacks
            )
            #expect(result.stoppedEarly)
            #expect(result.moved.isEmpty)
            // Second source must remain untouched
            #expect(FileManager.default.fileExists(atPath: s2.path))
        }
    }

    @Test("Undo restores files to their original locations")
    func undoRestoresFiles() async throws {
        try await withTempBase { base in
            let src = try makeFile(at: base.appendingPathComponent("source/a.ai"), contents: "hello")
            let match = Match(
                source: SourceFile(url: src, nameStem: "a", relativePath: "source/a.ai", baseFolder: base),
                row: MappingRow(id: 0, fileName: "a", folderName: "Material One"),
                normalised: false
            )
            let result = await MoveExecutor.apply(
                matches: [match], destinationFolder: base, mode: .move, callbacks: .silent
            )
            #expect(result.moved.count == 1)

            let undo = await MoveExecutor.undo(result.moved, mode: .move)
            #expect(undo.errors.isEmpty)
            #expect(undo.reverted.count == 1)
            #expect(FileManager.default.fileExists(atPath: src.path))
            let restored = try String(contentsOf: src, encoding: .utf8)
            #expect(restored == "hello")
        }
    }

    @Test("Progress callback fires per-item and finishes at total")
    func progressCallbackFiresPerItem() async throws {
        try await withTempBase { base in
            let s1 = try makeFile(at: base.appendingPathComponent("src/a.ai"))
            let s2 = try makeFile(at: base.appendingPathComponent("src/b.ai"))
            let matches = [
                Match(source: SourceFile(url: s1, nameStem: "a", relativePath: "src/a.ai", baseFolder: base),
                      row: MappingRow(id: 0, fileName: "a", folderName: "M"), normalised: false),
                Match(source: SourceFile(url: s2, nameStem: "b", relativePath: "src/b.ai", baseFolder: base),
                      row: MappingRow(id: 1, fileName: "b", folderName: "M"), normalised: false),
            ]
            actor Capture { var ticks: [MoveProgress] = []; func add(_ p: MoveProgress) { ticks.append(p) } }
            let capture = Capture()
            let callbacks = MoveExecutorCallbacks(
                onProgress: { p in await capture.add(p) },
                onCollision: { _, _ in .skip(forAll: false) }
            )
            _ = await MoveExecutor.apply(matches: matches, destinationFolder: base, mode: .move, callbacks: callbacks)
            await #expect(capture.ticks.last?.done == 2)
            await #expect(capture.ticks.last?.total == 2)
        }
    }

    // MARK: - Copy mode

    @Test("Copy mode duplicates the file and leaves the original in place")
    func copyLeavesOriginal() async throws {
        try await withTempBase { base in
            let src = try makeFile(at: base.appendingPathComponent("source/a.ai"), contents: "hello")
            let match = Match(
                source: SourceFile(url: src, nameStem: "a", relativePath: "source/a.ai", baseFolder: base),
                row: MappingRow(id: 0, fileName: "a", folderName: "Material One"),
                normalised: false
            )
            let result = await MoveExecutor.apply(
                matches: [match], destinationFolder: base, mode: .copy, callbacks: .silent
            )
            #expect(result.moved.count == 1)
            #expect(result.errors.isEmpty)
            let dst = base.appendingPathComponent("Material One/a.ai")
            #expect(FileManager.default.fileExists(atPath: dst.path))
            #expect(try String(contentsOf: dst, encoding: .utf8) == "hello")
            // The original must still be exactly where it was.
            #expect(FileManager.default.fileExists(atPath: src.path))
            #expect(try String(contentsOf: src, encoding: .utf8) == "hello")
        }
    }

    @Test("Undo of a copy deletes the copies and never touches the originals")
    func undoCopyDeletesCopies() async throws {
        try await withTempBase { base in
            let src = try makeFile(at: base.appendingPathComponent("source/a.ai"), contents: "hello")
            let match = Match(
                source: SourceFile(url: src, nameStem: "a", relativePath: "source/a.ai", baseFolder: base),
                row: MappingRow(id: 0, fileName: "a", folderName: "Material One"),
                normalised: false
            )
            let result = await MoveExecutor.apply(
                matches: [match], destinationFolder: base, mode: .copy, callbacks: .silent
            )
            #expect(result.moved.count == 1)

            let undo = await MoveExecutor.undo(result.moved, mode: .copy)
            #expect(undo.errors.isEmpty)
            #expect(undo.reverted.count == 1)
            let dst = base.appendingPathComponent("Material One/a.ai")
            #expect(!FileManager.default.fileExists(atPath: dst.path))
            #expect(FileManager.default.fileExists(atPath: src.path))
            #expect(try String(contentsOf: src, encoding: .utf8) == "hello")
        }
    }

    @Test("Copy-mode collision Replace overwrites the destination, original intact")
    func copyCollisionReplaceOverwrites() async throws {
        try await withTempBase { base in
            let src = try makeFile(at: base.appendingPathComponent("source/a.ai"), contents: "new")
            let dst = try makeFile(at: base.appendingPathComponent("Material One/a.ai"), contents: "existing")
            let match = Match(
                source: SourceFile(url: src, nameStem: "a", relativePath: "source/a.ai", baseFolder: base),
                row: MappingRow(id: 0, fileName: "a", folderName: "Material One"),
                normalised: false
            )
            let callbacks = MoveExecutorCallbacks(
                onProgress: { _ in },
                onCollision: { _, _ in .replace(forAll: false) }
            )
            let result = await MoveExecutor.apply(
                matches: [match], destinationFolder: base, mode: .copy, callbacks: callbacks
            )
            #expect(result.moved.count == 1)
            #expect(try String(contentsOf: dst, encoding: .utf8) == "new")
            #expect(FileManager.default.fileExists(atPath: src.path))
        }
    }

    // MARK: - helpers

    private func withTempBase(_ work: (URL) async throws -> Void) async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("FileShufflerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await work(dir)
    }

    @discardableResult
    private func makeFile(at url: URL, contents: String = "x") throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }
}
