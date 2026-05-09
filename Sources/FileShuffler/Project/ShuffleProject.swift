import Foundation

/// On-disk representation of a saved job. `.shuffle` files are tiny JSON
/// sidecars — saving one captures the inputs (folder, sheet, column choices)
/// and, after an apply, the audit log too. Reopening one restores the same
/// state so the operator can pick up where they left off.
///
/// Paths are stored absolute. We deliberately don't try to resolve them
/// relative to the project file's location: jobs typically live in stable
/// places (Desktop / shared volume) and a too-clever resolver hides
/// genuinely-broken setups behind silent fallbacks.
struct ShuffleProject: Codable, Equatable {
    /// Bumps when the on-disk schema changes. Old files older than this
    /// version get a friendly "this project was saved by a newer version"
    /// error rather than partial decoding.
    static let currentVersion = 1

    var version: Int
    var baseFolderPath: String
    var sheetPath: String
    var fileColumn: String
    var folderColumn: String
    /// `nil` means the operator did not pick a quantity column for this job.
    var quantityColumn: String?
    var savedAt: Date
    /// Most recent successful apply pass. Lets the operator reopen a job
    /// tomorrow and still export the log.
    var auditLog: AuditLog?

    init(
        baseFolderPath: String,
        sheetPath: String,
        fileColumn: String,
        folderColumn: String,
        quantityColumn: String?,
        auditLog: AuditLog? = nil,
        savedAt: Date = Date()
    ) {
        self.version = ShuffleProject.currentVersion
        self.baseFolderPath = baseFolderPath
        self.sheetPath = sheetPath
        self.fileColumn = fileColumn
        self.folderColumn = folderColumn
        self.quantityColumn = quantityColumn
        self.savedAt = savedAt
        self.auditLog = auditLog
    }
}

/// Record of a completed apply pass. Built from `MoveResult` plus a few
/// pieces of context (what folder, what sheet, when) that aren't on the
/// result itself but are useful when reading the log later.
struct AuditLog: Codable, Equatable {
    var startedAt: Date
    var finishedAt: Date
    var operatorName: String
    var baseFolderPath: String
    var sheetPath: String
    var moves: [LoggedMove]
    var skipped: [String]              // relative source paths
    var errors: [LoggedError]
    var stoppedEarly: Bool
    /// Relative paths of source folders that were removed in the cleanup
    /// pass, if the operator opted in. Optional in JSON for backwards-
    /// compatibility with `.shuffle` files saved before cleanup existed.
    var cleanedUpFolders: [String]?

    var totals: (moved: Int, skipped: Int, errors: Int) {
        (moves.count, skipped.count, errors.count)
    }
}

struct LoggedMove: Codable, Equatable {
    var src: String                    // absolute path
    var dst: String
}

struct LoggedError: Codable, Equatable {
    var src: String                    // absolute path of the problem file
    var message: String
}

// MARK: - Errors

enum ProjectIOError: LocalizedError {
    case unsupportedVersion(found: Int, supported: Int)
    case decodeFailed(String)
    case encodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let f, let s):
            return "This project file was saved by a newer version of File Shuffler (v\(f); this build supports v\(s)). Please update."
        case .decodeFailed(let m): return "Could not read project file: \(m)"
        case .encodeFailed(let m): return "Could not write project file: \(m)"
        }
    }
}

// MARK: - I/O

enum ShuffleProjectIO {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func save(_ project: ShuffleProject, to url: URL) throws {
        do {
            let data = try encoder.encode(project)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ProjectIOError.encodeFailed(error.localizedDescription)
        }
    }

    static func load(from url: URL) throws -> ShuffleProject {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ProjectIOError.decodeFailed(error.localizedDescription)
        }
        let project: ShuffleProject
        do {
            project = try decoder.decode(ShuffleProject.self, from: data)
        } catch {
            throw ProjectIOError.decodeFailed(error.localizedDescription)
        }
        guard project.version <= ShuffleProject.currentVersion else {
            throw ProjectIOError.unsupportedVersion(
                found: project.version,
                supported: ShuffleProject.currentVersion
            )
        }
        return project
    }
}

// MARK: - Audit log builder & exporter

extension AuditLog {
    /// Build an audit log from a finished apply pass.
    init(
        from result: MoveResult,
        startedAt: Date,
        finishedAt: Date = Date(),
        baseFolder: URL,
        sheetURL: URL?,
        operatorName: String = NSFullUserName()
    ) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.operatorName = operatorName
        self.baseFolderPath = baseFolder.path
        self.sheetPath = sheetURL?.path ?? ""
        self.moves = result.moved.map { LoggedMove(src: $0.src.path, dst: $0.dst.path) }
        self.skipped = result.skipped.map(\.source.relativePath)
        self.errors = result.errors.map {
            LoggedError(src: $0.match.source.url.path, message: $0.message)
        }
        self.stoppedEarly = result.stoppedEarly
        self.cleanedUpFolders = nil    // populated later if cleanup is run
    }

    /// Plain-text export. Designed to be readable as-is in a terminal or a
    /// printout filed alongside the production folder. Intentionally not
    /// fancy — every line is `src -> dst` so an operator can scan quickly
    /// for what they expect to see.
    func plainTextReport() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var out = ""
        out += "File Shuffler — Audit Log\n"
        out += "==========================\n\n"
        out += "Operator:    \(operatorName)\n"
        out += "Started:     \(formatter.string(from: startedAt))\n"
        out += "Finished:    \(formatter.string(from: finishedAt))\n"
        out += "Base folder: \(baseFolderPath)\n"
        if !sheetPath.isEmpty {
            out += "Spreadsheet: \(sheetPath)\n"
        }
        out += "\nSummary:\n"
        out += "  Moved:   \(moves.count)\n"
        out += "  Skipped: \(skipped.count)\n"
        out += "  Errors:  \(errors.count)\n"
        if stoppedEarly {
            out += "  (Apply was cancelled mid-run.)\n"
        }
        out += "\nMoves:\n"
        if moves.isEmpty {
            out += "  (none)\n"
        } else {
            for m in moves { out += "  \(m.src)\n    -> \(m.dst)\n" }
        }
        if !skipped.isEmpty {
            out += "\nSkipped:\n"
            for s in skipped { out += "  \(s)\n" }
        }
        if !errors.isEmpty {
            out += "\nErrors:\n"
            for e in errors { out += "  \(e.src)\n    \(e.message)\n" }
        }
        if let cleaned = cleanedUpFolders, !cleaned.isEmpty {
            out += "\nEmpty source folders removed:\n"
            for f in cleaned { out += "  \(f)\n" }
        }
        return out
    }
}
