import Foundation

/// Pure-functional matching engine.
///
/// The rules here intentionally mirror the existing `reorganize.py` script so
/// the app and the CLI can never disagree about whether a filename matches a
/// sheet row. Whenever the rules change, update both.
enum MatchEngine {

    /// Lowercase, trim, and collapse runs of whitespace to a single space.
    /// Hand-curated spreadsheets routinely have stray double-spaces and
    /// inconsistent capitalisation; everything else (punctuation, hyphens,
    /// numbers) we leave alone so we don't paper over real differences.
    static func normalise(_ s: String) -> String {
        let lowered = s.lowercased()
        let parts = lowered.split(whereSeparator: { $0.isWhitespace })
        return parts.joined(separator: " ")
    }

    /// One operator decision per conflicted row. Indexed by `MappingRow.id`
    /// so the UI can rebuild this dictionary as the operator clicks
    /// candidates without losing earlier picks.
    enum ConflictResolution: Equatable {
        /// Use this specific source file for the row; treat the other
        /// candidates as orphans (move to `filesNotInSheet`).
        case use(URL)
        /// Skip the row entirely; all candidates become orphans.
        case skip
    }

    /// Build a plan: which files match which rows, which rows are orphaned,
    /// which files are orphaned, and which rows have multiple files claiming
    /// to be them. No mutation of the inputs, no I/O.
    ///
    /// Matching runs in two passes:
    ///
    ///   1. **Exact**, on the normalised stem. Catches the common case and
    ///      preserves any legitimate `_xN` filenames in either the sheet
    ///      or on disk.
    ///   2. **Stripped**, only for rows that didn't match in Pass 1. Strips
    ///      a trailing `_xN` suffix from the file's stem before comparing,
    ///      catching files that were renamed by a previous run of the app
    ///      (the idempotency case). Pass-2 matches are flagged so the UI
    ///      can show ⚠ and the destination-filename builder knows the
    ///      existing `_xN` is ours to replace, not user data to preserve.
    ///
    /// `resolutions` is consulted whenever a row has multiple candidates.
    /// Without an entry the row goes to `conflicts` and Apply stays blocked;
    /// with one, the chosen file becomes a regular `Match` and the others
    /// fall into `filesNotInSheet`.
    static func plan(
        files: [SourceFile],
        rows: [MappingRow],
        resolutions: [Int: ConflictResolution] = [:]
    ) -> MatchPlan {
        var matched: [Match] = []
        var conflicts: [Conflict] = []
        var sheetOrphans: [MappingRow] = []
        var consumed = Set<Int>()

        // Pass 1: exact normalised match — but capture *all* files per key
        // so we can detect collisions across multiple source folders.
        var exactBuckets: [String: [Int]] = [:]
        for (i, f) in files.enumerated() {
            exactBuckets[normalise(f.nameStem), default: []].append(i)
        }

        var unmatchedRows: [MappingRow] = []
        for row in rows {
            let key = normalise(row.fileName)
            let candidates = (exactBuckets[key] ?? []).filter { !consumed.contains($0) }
            if candidates.isEmpty {
                unmatchedRows.append(row)
                continue
            }
            if candidates.count == 1 {
                let idx = candidates[0]
                consumed.insert(idx)
                let f = files[idx]
                let needsNorm = (f.nameStem != row.fileName)
                matched.append(Match(
                    source: f, row: row,
                    normalised: needsNorm,
                    stemMatchedAfterStrip: false
                ))
            } else {
                // Multiple files for one row — defer to operator. If the
                // UI has already supplied a resolution, honour it now;
                // otherwise file the row in `conflicts`.
                if let resolution = resolutions[row.id] {
                    applyResolution(
                        resolution,
                        row: row,
                        candidates: candidates,
                        files: files,
                        normalisedFlag: { f in f.nameStem != row.fileName },
                        stemMatchedAfterStrip: false,
                        matched: &matched,
                        consumed: &consumed,
                        sheetOrphans: &sheetOrphans
                    )
                } else {
                    conflicts.append(Conflict(
                        row: row,
                        candidates: candidates.map { files[$0] }
                    ))
                    candidates.forEach { consumed.insert($0) }
                }
            }
        }

        // Pass 2: try matching unmatched rows against unconsumed files
        // with a trailing `_xN` suffix stripped from the file's stem.
        if !unmatchedRows.isEmpty {
            var strippedBuckets: [String: [Int]] = [:]
            for (i, f) in files.enumerated() where !consumed.contains(i) {
                let stripped = stripQuantitySuffix(normalise(f.nameStem))
                strippedBuckets[stripped, default: []].append(i)
            }
            for row in unmatchedRows {
                let key = normalise(row.fileName)
                let candidates = (strippedBuckets[key] ?? []).filter { !consumed.contains($0) }
                if candidates.isEmpty {
                    sheetOrphans.append(row)
                    continue
                }
                if candidates.count == 1 {
                    let idx = candidates[0]
                    consumed.insert(idx)
                    let f = files[idx]
                    matched.append(Match(
                        source: f, row: row,
                        // Always flag normalised so the operator sees the
                        // ⚠ icon — Pass 2 by definition required a tweak.
                        normalised: true,
                        stemMatchedAfterStrip: true
                    ))
                } else {
                    if let resolution = resolutions[row.id] {
                        applyResolution(
                            resolution,
                            row: row,
                            candidates: candidates,
                            files: files,
                            normalisedFlag: { _ in true },
                            stemMatchedAfterStrip: true,
                            matched: &matched,
                            consumed: &consumed,
                            sheetOrphans: &sheetOrphans
                        )
                    } else {
                        conflicts.append(Conflict(
                            row: row,
                            candidates: candidates.map { files[$0] }
                        ))
                        candidates.forEach { consumed.insert($0) }
                    }
                }
            }
        }

        let fileOrphans = files.enumerated()
            .filter { !consumed.contains($0.offset) }
            .map { $0.element }

        return MatchPlan(
            matched: matched,
            conflicts: conflicts,
            sheetRowsWithoutFile: sheetOrphans,
            filesNotInSheet: fileOrphans
        )
    }

    /// Applies an operator's conflict pick. The chosen file becomes a
    /// `Match`; the rest are released back into the unconsumed pool so
    /// they can either match a different row (rare but possible after
    /// Pass 2) or fall through to `filesNotInSheet`.
    private static func applyResolution(
        _ resolution: ConflictResolution,
        row: MappingRow,
        candidates: [Int],
        files: [SourceFile],
        normalisedFlag: (SourceFile) -> Bool,
        stemMatchedAfterStrip: Bool,
        matched: inout [Match],
        consumed: inout Set<Int>,
        sheetOrphans: inout [MappingRow]
    ) {
        switch resolution {
        case .use(let chosenURL):
            if let pickedIdx = candidates.first(where: { files[$0].url == chosenURL }) {
                consumed.insert(pickedIdx)
                let f = files[pickedIdx]
                matched.append(Match(
                    source: f, row: row,
                    normalised: normalisedFlag(f),
                    stemMatchedAfterStrip: stemMatchedAfterStrip
                ))
                // Other candidates remain unconsumed so they fall into
                // `filesNotInSheet` at the end.
            } else {
                // Resolution points at a file that's no longer a candidate
                // (e.g. the operator removed that source after picking).
                // Treat as if no resolution was given.
                candidates.forEach { consumed.insert($0) }
                sheetOrphans.append(row)
            }
        case .skip:
            // Skip the row; release candidates back to the unconsumed pool
            // by *not* marking them consumed.
            sheetOrphans.append(row)
        }
    }

    /// Strip a trailing `_x` followed by digits from the very end of a
    /// string. Used to make the matcher (and the rename builder) idempotent
    /// across re-runs of the app's Quantity feature. Case-insensitive on
    /// the `x` so legacy files that happen to use `_X12` still strip. We
    /// refuse to return an empty string — that would happen for a stem of
    /// e.g. just `_x12` and would falsely match anything else stripped
    /// to empty.
    static func stripQuantitySuffix(_ s: String) -> String {
        if let range = s.range(of: #"_x\d+$"#, options: [.regularExpression, .caseInsensitive]) {
            let stripped = String(s[..<range.lowerBound])
            return stripped.isEmpty ? s : stripped
        }
        return s
    }
}
