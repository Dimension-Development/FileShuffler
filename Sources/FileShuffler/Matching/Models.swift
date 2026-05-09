import Foundation

/// One file discovered on disk under the base folder.
struct SourceFile: Identifiable, Hashable {
    let url: URL
    let nameStem: String      // filename without extension
    let relativePath: String  // path relative to the base folder
    var id: URL { url }
}

/// One row in the mapping spreadsheet.
struct MappingRow: Identifiable, Hashable {
    let id: Int               // sheet row number, kept for stable identity in UI
    let fileName: String
    let folderName: String
}

/// One successful match between a file on disk and a sheet row.
struct Match: Identifiable, Hashable {
    let source: SourceFile
    let row: MappingRow
    /// True when the names only matched after whitespace/case normalisation —
    /// surfaced in the UI so the operator can sanity-check the "almost match".
    let normalised: Bool
    var id: URL { source.url }
    var destination: String { row.folderName }
}

/// The full result of the matching pass — exactly the three buckets the
/// operator needs to see before any file moves.
struct MatchPlan: Equatable {
    var matched: [Match]
    var sheetRowsWithoutFile: [MappingRow]
    var filesNotInSheet: [SourceFile]
}
