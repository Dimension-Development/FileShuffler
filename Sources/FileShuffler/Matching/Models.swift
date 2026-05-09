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
    /// Optional print quantity. When non-nil and non-empty after trimming,
    /// the destination filename gets a `_x<quantity>` suffix before its
    /// extension — e.g. `foo.ai` → `foo_x30.ai`. Sourced from a "Quantity"
    /// (or "Qty") column the operator can opt into per job.
    var quantity: String?

    init(id: Int, fileName: String, folderName: String, quantity: String? = nil) {
        self.id = id
        self.fileName = fileName
        self.folderName = folderName
        self.quantity = quantity
    }
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

    /// Filename to use at the destination. When `row.quantity` is non-empty,
    /// suffix `_x<quantity>` before the extension. Built once here rather
    /// than recomputed in two places (executor + UI) so a name change only
    /// needs to be made in one location.
    var destinationFilename: String {
        let original = source.url.lastPathComponent
        guard
            let raw = row.quantity?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return original
        }
        let ns = original as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        return ext.isEmpty ? "\(stem)_x\(raw)" : "\(stem)_x\(raw).\(ext)"
    }

    /// True when the destination filename differs from the source filename —
    /// the UI uses this to decorate the row and make the rename visible.
    var willRename: Bool {
        destinationFilename != source.url.lastPathComponent
    }
}

/// The full result of the matching pass — exactly the three buckets the
/// operator needs to see before any file moves.
struct MatchPlan: Equatable {
    var matched: [Match]
    var sheetRowsWithoutFile: [MappingRow]
    var filesNotInSheet: [SourceFile]
}
