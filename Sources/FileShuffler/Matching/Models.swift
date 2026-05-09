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
    /// True when the names only matched after whitespace/case normalisation
    /// or `_xN`-suffix stripping — surfaced in the UI as the ⚠ icon so the
    /// operator can sanity-check the "almost match".
    let normalised: Bool
    /// True when the matcher had to strip a trailing `_xN` suffix from the
    /// file's stem to find this row — meaning the file looks like one a
    /// previous run of the app produced. Drives the rename behaviour: when
    /// true, an existing `_xN` is replaced rather than stacked.
    let stemMatchedAfterStrip: Bool
    var id: URL { source.url }
    var destination: String { row.folderName }

    init(
        source: SourceFile,
        row: MappingRow,
        normalised: Bool,
        stemMatchedAfterStrip: Bool = false
    ) {
        self.source = source
        self.row = row
        self.normalised = normalised
        self.stemMatchedAfterStrip = stemMatchedAfterStrip
    }

    /// Filename to use at the destination. When `row.quantity` is non-empty,
    /// suffix `_x<quantity>` before the extension.
    ///
    /// If we matched this file via Pass-2 stripping, the existing `_xN` was
    /// added by a previous run and is ours to manage — replace it. If the
    /// match was exact (Pass 1), any `_xN` already in the filename is user
    /// data and we preserve it; the new quantity stacks on the end. The
    /// plan view shows the final destination filename either way, so the
    /// operator can spot anything unexpected before applying.
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
        var stem = ns.deletingPathExtension
        if stemMatchedAfterStrip {
            stem = MatchEngine.stripQuantitySuffix(stem)
        }
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
