import Testing
import Foundation
@testable import FileShuffler

@Suite("FolderCleanup")
struct FolderCleanupTests {

    @Test("Source folders that emptied during apply are surfaced as candidates")
    func emptiedSourceFoldersAreCandidates() async throws {
        try await withTempBase { base in
            // Mimic a real job: brand subfolders containing one file each,
            // already moved out, leaving the parent dirs empty.
            let arenciaFolder = base.appendingPathComponent("261144 - Arencia")
            try FileManager.default.createDirectory(at: arenciaFolder, withIntermediateDirectories: true)

            let movedSrc = arenciaFolder.appendingPathComponent("file.ai")
            // Note: file no longer exists at src — that's the post-apply state.
            let move = Move(
                src: movedSrc,
                dst: base.appendingPathComponent("Material/file.ai")
            )

            let candidates = FolderCleanup.candidates(from: [move], baseFolder: base)
            #expect(candidates.count == 1)
            #expect(candidates.first?.relativePath == "261144 - Arencia")
        }
    }

    @Test("A folder containing only .DS_Store is treated as empty")
    func dsStoreOnlyIsEmpty() async throws {
        try await withTempBase { base in
            let folder = base.appendingPathComponent("brand-a")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent(".DS_Store"))

            let move = Move(
                src: folder.appendingPathComponent("artwork.ai"),
                dst: base.appendingPathComponent("Material/artwork.ai")
            )
            let candidates = FolderCleanup.candidates(from: [move], baseFolder: base)
            #expect(candidates.count == 1)
        }
    }

    @Test("Folders with non-ignorable leftover files are NOT candidates")
    func nonEmptySourceFolderIsNotACandidate() async throws {
        try await withTempBase { base in
            let folder = base.appendingPathComponent("brand-a")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Leftover that isn't .DS_Store — operator might want this kept
            try Data("notes".utf8).write(to: folder.appendingPathComponent("notes.txt"))

            let move = Move(
                src: folder.appendingPathComponent("artwork.ai"),
                dst: base.appendingPathComponent("Material/artwork.ai")
            )
            let candidates = FolderCleanup.candidates(from: [move], baseFolder: base)
            #expect(candidates.isEmpty, "should refuse to delete a folder with non-ignorable contents")
        }
    }

    @Test("Base folder is never proposed for cleanup")
    func baseFolderNeverInCandidates() async throws {
        try await withTempBase { base in
            // A move whose source's parent IS the base folder
            let move = Move(
                src: base.appendingPathComponent("a.ai"),
                dst: base.appendingPathComponent("Material/a.ai")
            )
            let candidates = FolderCleanup.candidates(from: [move], baseFolder: base)
            #expect(candidates.isEmpty)
        }
    }

    @Test("cleanUp removes the folder and its .DS_Store")
    func cleanUpRemovesFolderAndDSStore() async throws {
        try await withTempBase { base in
            let folder = base.appendingPathComponent("to-remove")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent(".DS_Store"))

            let candidate = EmptyFolderCandidate(url: folder, relativePath: "to-remove")
            let result = FolderCleanup.cleanUp([candidate])
            #expect(result.deleted.count == 1)
            #expect(result.errors.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: folder.path))
        }
    }

    @Test("Undo recreates the source folder structure even after cleanup")
    func undoStillRestoresAfterCleanup() async throws {
        try await withTempBase { base in
            // Create source layout, run an apply, then clean up, then undo.
            let folder = base.appendingPathComponent("brand-a")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let src = folder.appendingPathComponent("art.ai")
            try Data("hello".utf8).write(to: src)

            let match = Match(
                source: SourceFile(url: src, nameStem: "art", relativePath: "brand-a/art.ai"),
                row: MappingRow(id: 0, fileName: "art", folderName: "Material"),
                normalised: false
            )
            let result = await MoveExecutor.apply(matches: [match], baseFolder: base, callbacks: .silent)
            #expect(result.moved.count == 1)

            let candidates = FolderCleanup.candidates(from: result.moved, baseFolder: base)
            let cleanup = FolderCleanup.cleanUp(candidates)
            #expect(cleanup.deleted.count == 1)
            #expect(!FileManager.default.fileExists(atPath: folder.path))

            // Undo should restore the file — its parent folder is recreated
            // by the move executor's intermediate-directories flag.
            let undo = await MoveExecutor.undo(result.moved)
            #expect(undo.errors.isEmpty)
            #expect(FileManager.default.fileExists(atPath: src.path))
            #expect(FileManager.default.fileExists(atPath: folder.path))
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
}
