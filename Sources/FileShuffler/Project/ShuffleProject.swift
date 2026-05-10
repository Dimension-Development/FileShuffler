import Foundation

/// On-disk representation of a saved job. `.shuffle` files are tiny JSON
/// sidecars — saving one captures the inputs (source folders, destination,
/// sheet, column choices, conflict resolutions) and, after an apply, the
/// audit log too. Reopening one restores the same state so the operator
/// can pick up where they left off.
///
/// Paths are stored absolute. We deliberately don't try to resolve them
/// relative to the project file's location: jobs typically live in stable
/// places (Desktop / shared volume) and a too-clever resolver hides
/// genuinely-broken setups behind silent fallbacks.
struct ShuffleProject: Equatable {
    /// Bumps when the on-disk schema changes. Old files older than this
    /// version get a friendly "this project was saved by a newer version"
    /// error rather than partial decoding. v2 introduced multi-source +
    /// separate destination; the decoder still reads v1 files transparently.
    static let currentVersion = 2

    var version: Int
    var sourceFolderPaths: [String]
    var destinationPath: String
    var sheetPath: String
    var fileColumn: String
    var folderColumn: String
    /// `nil` means the operator did not pick a quantity column for this job.
    var quantityColumn: String?
    /// Operator picks captured per conflicted sheet row, keyed by the
    /// `MappingRow.id` (sheet row number). Stored as JSON-friendly strings.
    var conflictResolutions: [String: ResolutionRecord]
    var savedAt: Date
    /// Most recent successful apply pass. Lets the operator reopen a job
    /// tomorrow and still export the log.
    var auditLog: AuditLog?

    init(
        sourceFolderPaths: [String],
        destinationPath: String,
        sheetPath: String,
        fileColumn: String,
        folderColumn: String,
        quantityColumn: String?,
        conflictResolutions: [String: ResolutionRecord] = [:],
        auditLog: AuditLog? = nil,
        savedAt: Date = Date()
    ) {
        self.version = ShuffleProject.currentVersion
        self.sourceFolderPaths = sourceFolderPaths
        self.destinationPath = destinationPath
        self.sheetPath = sheetPath
        self.fileColumn = fileColumn
        self.folderColumn = folderColumn
        self.quantityColumn = quantityColumn
        self.conflictResolutions = conflictResolutions
        self.savedAt = savedAt
        self.auditLog = auditLog
    }
}

/// Persistent form of `MatchEngine.ConflictResolution`. Codable so the
/// operator's picks survive a save/load round-trip — important when a job
/// has dozens of conflicts and they want to come back to it tomorrow.
struct ResolutionRecord: Codable, Equatable {
    /// `"use"` (with `chosenPath` set to the picked file's absolute path)
    /// or `"skip"`.
    var kind: String
    var chosenPath: String?
}

extension ShuffleProject: Codable {
    private enum CodingKeys: String, CodingKey {
        case version
        case sourceFolderPaths
        case destinationPath
        case sheetPath
        case fileColumn
        case folderColumn
        case quantityColumn
        case conflictResolutions
        case savedAt
        case auditLog
        // v1-only — read on load, never written.
        case baseFolderPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        self.version = version
        self.sheetPath = try c.decode(String.self, forKey: .sheetPath)
        self.fileColumn = try c.decode(String.self, forKey: .fileColumn)
        self.folderColumn = try c.decode(String.self, forKey: .folderColumn)
        self.quantityColumn = try c.decodeIfPresent(String.self, forKey: .quantityColumn)
        self.savedAt = try c.decode(Date.self, forKey: .savedAt)
        self.auditLog = try c.decodeIfPresent(AuditLog.self, forKey: .auditLog)

        if version >= 2 {
            self.sourceFolderPaths = try c.decode([String].self, forKey: .sourceFolderPaths)
            self.destinationPath = try c.decode(String.self, forKey: .destinationPath)
            self.conflictResolutions = try c.decodeIfPresent(
                [String: ResolutionRecord].self, forKey: .conflictResolutions
            ) ?? [:]
        } else {
            // v1 → v2 migration: a single base folder served as both the
            // source and the destination. Promote it to a one-element
            // sources list with destination matching, so the operator's
            // saved job opens looking exactly like it did before.
            let single = try c.decode(String.self, forKey: .baseFolderPath)
            self.sourceFolderPaths = [single]
            self.destinationPath = single
            self.conflictResolutions = [:]
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(sourceFolderPaths, forKey: .sourceFolderPaths)
        try c.encode(destinationPath, forKey: .destinationPath)
        try c.encode(sheetPath, forKey: .sheetPath)
        try c.encode(fileColumn, forKey: .fileColumn)
        try c.encode(folderColumn, forKey: .folderColumn)
        try c.encodeIfPresent(quantityColumn, forKey: .quantityColumn)
        try c.encode(conflictResolutions, forKey: .conflictResolutions)
        try c.encode(savedAt, forKey: .savedAt)
        try c.encodeIfPresent(auditLog, forKey: .auditLog)
    }
}

/// Record of a completed apply pass. Built from `MoveResult` plus a few
/// pieces of context (which sources, which destination, which sheet, when)
/// that aren't on the result itself but are useful when reading the log
/// later.
struct AuditLog: Codable, Equatable {
    var startedAt: Date
    var finishedAt: Date
    var operatorName: String
    var sourceFolderPaths: [String]
    var destinationPath: String
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

    /// Read v1 audit logs (which had a single `baseFolderPath`) by
    /// promoting that field to a one-element `sourceFolderPaths` and
    /// reusing it as `destinationPath` — the v1 model conflated the two.
    private enum CodingKeys: String, CodingKey {
        case startedAt, finishedAt, operatorName
        case sourceFolderPaths, destinationPath
        case sheetPath, moves, skipped, errors, stoppedEarly, cleanedUpFolders
        case baseFolderPath  // v1 only
    }

    init(
        startedAt: Date,
        finishedAt: Date,
        operatorName: String,
        sourceFolderPaths: [String],
        destinationPath: String,
        sheetPath: String,
        moves: [LoggedMove],
        skipped: [String],
        errors: [LoggedError],
        stoppedEarly: Bool,
        cleanedUpFolders: [String]? = nil
    ) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.operatorName = operatorName
        self.sourceFolderPaths = sourceFolderPaths
        self.destinationPath = destinationPath
        self.sheetPath = sheetPath
        self.moves = moves
        self.skipped = skipped
        self.errors = errors
        self.stoppedEarly = stoppedEarly
        self.cleanedUpFolders = cleanedUpFolders
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.startedAt = try c.decode(Date.self, forKey: .startedAt)
        self.finishedAt = try c.decode(Date.self, forKey: .finishedAt)
        self.operatorName = try c.decode(String.self, forKey: .operatorName)
        self.sheetPath = try c.decode(String.self, forKey: .sheetPath)
        self.moves = try c.decode([LoggedMove].self, forKey: .moves)
        self.skipped = try c.decode([String].self, forKey: .skipped)
        self.errors = try c.decode([LoggedError].self, forKey: .errors)
        self.stoppedEarly = try c.decode(Bool.self, forKey: .stoppedEarly)
        self.cleanedUpFolders = try c.decodeIfPresent([String].self, forKey: .cleanedUpFolders)

        if let sources = try c.decodeIfPresent([String].self, forKey: .sourceFolderPaths) {
            self.sourceFolderPaths = sources
            self.destinationPath = try c.decode(String.self, forKey: .destinationPath)
        } else {
            // v1 audit log — one base served as both source and destination.
            let single = try c.decode(String.self, forKey: .baseFolderPath)
            self.sourceFolderPaths = [single]
            self.destinationPath = single
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(finishedAt, forKey: .finishedAt)
        try c.encode(operatorName, forKey: .operatorName)
        try c.encode(sourceFolderPaths, forKey: .sourceFolderPaths)
        try c.encode(destinationPath, forKey: .destinationPath)
        try c.encode(sheetPath, forKey: .sheetPath)
        try c.encode(moves, forKey: .moves)
        try c.encode(skipped, forKey: .skipped)
        try c.encode(errors, forKey: .errors)
        try c.encode(stoppedEarly, forKey: .stoppedEarly)
        try c.encodeIfPresent(cleanedUpFolders, forKey: .cleanedUpFolders)
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
        sourceFolders: [URL],
        destinationFolder: URL,
        sheetURL: URL?,
        operatorName: String = NSFullUserName()
    ) {
        self.init(
            startedAt: startedAt,
            finishedAt: finishedAt,
            operatorName: operatorName,
            sourceFolderPaths: sourceFolders.map(\.path),
            destinationPath: destinationFolder.path,
            sheetPath: sheetURL?.path ?? "",
            moves: result.moved.map { LoggedMove(src: $0.src.path, dst: $0.dst.path) },
            skipped: result.skipped.map(\.source.relativePath),
            errors: result.errors.map {
                LoggedError(src: $0.match.source.url.path, message: $0.message)
            },
            stoppedEarly: result.stoppedEarly,
            cleanedUpFolders: nil
        )
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
        if sourceFolderPaths.count == 1 {
            out += "Source:      \(sourceFolderPaths[0])\n"
        } else {
            out += "Sources:\n"
            for s in sourceFolderPaths { out += "  \(s)\n" }
        }
        out += "Destination: \(destinationPath)\n"
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
