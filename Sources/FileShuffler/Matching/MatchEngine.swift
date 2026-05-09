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

    /// Build a plan: which files match which rows, which rows are orphaned,
    /// which files are orphaned. No mutation of the inputs, no I/O.
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
    static func plan(files: [SourceFile], rows: [MappingRow]) -> MatchPlan {
        var matched: [Match] = []
        var sheetOrphans: [MappingRow] = []
        var consumed = Set<Int>()

        // Pass 1: exact normalised match.
        var exactIndex: [String: Int] = [:]
        exactIndex.reserveCapacity(files.count)
        for (i, f) in files.enumerated() {
            let key = normalise(f.nameStem)
            if exactIndex[key] == nil { exactIndex[key] = i }
        }

        var unmatchedRows: [MappingRow] = []
        for row in rows {
            let key = normalise(row.fileName)
            if let idx = exactIndex[key], !consumed.contains(idx) {
                consumed.insert(idx)
                let f = files[idx]
                let needsNorm = (f.nameStem != row.fileName)
                matched.append(Match(
                    source: f, row: row,
                    normalised: needsNorm,
                    stemMatchedAfterStrip: false
                ))
            } else {
                unmatchedRows.append(row)
            }
        }

        // Pass 2: try matching unmatched rows against unconsumed files
        // with a trailing `_xN` suffix stripped from the file's stem.
        if !unmatchedRows.isEmpty {
            var strippedIndex: [String: Int] = [:]
            for (i, f) in files.enumerated() where !consumed.contains(i) {
                let stripped = stripQuantitySuffix(normalise(f.nameStem))
                if strippedIndex[stripped] == nil { strippedIndex[stripped] = i }
            }
            for row in unmatchedRows {
                let key = normalise(row.fileName)
                if let idx = strippedIndex[key], !consumed.contains(idx) {
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
                    sheetOrphans.append(row)
                }
            }
        }

        let fileOrphans = files.enumerated()
            .filter { !consumed.contains($0.offset) }
            .map { $0.element }

        return MatchPlan(
            matched: matched,
            sheetRowsWithoutFile: sheetOrphans,
            filesNotInSheet: fileOrphans
        )
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
