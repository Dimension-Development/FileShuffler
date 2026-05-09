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
    static func plan(files: [SourceFile], rows: [MappingRow]) -> MatchPlan {
        // Index files by normalised stem so each row lookup is O(1).
        var indexByKey: [String: Int] = [:]
        indexByKey.reserveCapacity(files.count)
        for (i, f) in files.enumerated() {
            // First write wins; if there's a duplicate the second file falls
            // through to "files not in sheet" and we surface it explicitly.
            let key = normalise(f.nameStem)
            if indexByKey[key] == nil { indexByKey[key] = i }
        }

        var matched: [Match] = []
        var sheetOrphans: [MappingRow] = []
        var consumed = Set<Int>()

        for row in rows {
            let key = normalise(row.fileName)
            if let idx = indexByKey[key], !consumed.contains(idx) {
                consumed.insert(idx)
                let f = files[idx]
                let needsNorm = (f.nameStem != row.fileName)
                matched.append(Match(source: f, row: row, normalised: needsNorm))
            } else {
                sheetOrphans.append(row)
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
}
