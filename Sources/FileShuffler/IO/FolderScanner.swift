import Foundation

/// Walks a directory tree, returning the regular files we'd consider for
/// reorganising. Hidden files are skipped because `.DS_Store` and friends
/// have no business in the plan view, and the spreadsheet itself is
/// excluded by absolute URL so it doesn't try to move itself.
enum FolderScanner {
    static func scan(base: URL, excluding excluded: Set<URL> = []) throws -> [SourceFile] {
        let fm = FileManager.default
        let resolvedBase = base.standardizedFileURL.resolvingSymlinksInPath()
        let basePath = resolvedBase.path

        guard let enumerator = fm.enumerator(
            at: resolvedBase,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var result: [SourceFile] = []
        for case let url as URL in enumerator {
            let std = url.standardizedFileURL.resolvingSymlinksInPath()
            if excluded.contains(std) { continue }
            let values = try std.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }

            let stem = std.deletingPathExtension().lastPathComponent
            let path = std.path
            let relative: String
            if path.hasPrefix(basePath + "/") {
                relative = String(path.dropFirst(basePath.count + 1))
            } else {
                relative = std.lastPathComponent
            }
            result.append(SourceFile(
                url: std,
                nameStem: stem,
                relativePath: relative,
                baseFolder: resolvedBase
            ))
        }
        return result
    }

    /// Multi-source scan used by the welcome screen when the operator has
    /// added more than one paste-link to the same job. Each base is scanned
    /// independently and the results concatenated; `baseFolder` on each
    /// `SourceFile` lets callers tell which paste-link a file came from.
    /// Bases that fail to scan surface their error; partial results from
    /// successful bases are not returned (consistent with the single-base
    /// version's all-or-nothing semantics).
    static func scan(bases: [URL], excluding excluded: Set<URL> = []) throws -> [SourceFile] {
        var out: [SourceFile] = []
        for base in bases {
            let files = try scan(base: base, excluding: excluded)
            out.append(contentsOf: files)
        }
        return out
    }
}
