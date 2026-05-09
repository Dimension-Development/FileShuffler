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
            result.append(SourceFile(url: std, nameStem: stem, relativePath: relative))
        }
        return result
    }
}
