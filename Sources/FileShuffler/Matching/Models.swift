import Foundation

/// One file discovered on disk under one of the source folders the
/// operator selected. `baseFolder` is the source root this file lives
/// under — it stays attached so the plan view can prefix orphans with
/// "which paste-link did this come from?" when the operator added
/// multiple sources to the same job.
struct SourceFile: Identifiable, Hashable {
    let url: URL
    let nameStem: String       // filename without extension
    let relativePath: String   // path relative to `baseFolder`
    let baseFolder: URL        // which source root this file came from
    var id: URL { url }

    /// Path the UI shows to the operator. Single-source jobs see just the
    /// relative path (matches the v1 behaviour). Multi-source jobs see
    /// `<source folder> / <relative path>` so the source is unambiguous
    /// when reading the plan or a conflict.
    func displayPath(showingBase: Bool) -> String {
        showingBase
            ? "\(baseFolder.lastPathComponent) / \(relativePath)"
            : relativePath
    }
}

/// One file-to-folder mapping derived from the spreadsheet. Usually one
/// per sheet row; a row with both a front and a back artwork column emits
/// two.
struct MappingRow: Identifiable, Hashable {
    /// Stable identity for the UI and for persisted conflict resolutions.
    /// Derived from the sheet row index: front file = 2n, back file = 2n+1.
    let id: Int
    let fileName: String
    /// Destination path relative to the destination folder. A single
    /// sanitised folder name, or `<folder>/<subfolder>` when the job uses
    /// a subfolder column (e.g. Material/Colour Spec).
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

/// One spreadsheet row that has more than one file claiming to be it.
/// Surfaces in the plan view as a red "Conflicts" section. Apply is
/// blocked until the operator either picks a candidate or chooses to
/// skip the row entirely — silent picks here would defeat the whole
/// point of the app.
struct Conflict: Identifiable, Equatable {
    let row: MappingRow
    let candidates: [SourceFile]
    var id: Int { row.id }
}

/// The full result of the matching pass. Single-source jobs typically
/// see no conflicts; multi-source jobs use the `conflicts` bucket when
/// two source folders both contain a file matching the same sheet row.
struct MatchPlan: Equatable {
    var matched: [Match]
    var conflicts: [Conflict]
    var sheetRowsWithoutFile: [MappingRow]
    var filesNotInSheet: [SourceFile]
}
