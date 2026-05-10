import Foundation

/// A folder that's a candidate for removal after an apply pass: it used to
/// contain at least one source file we moved, and is now empty (or only
/// contains entries we consider ignorable like `.DS_Store`).
struct EmptyFolderCandidate: Identifiable, Hashable, Sendable {
    let url: URL
    let relativePath: String
    var id: URL { url }
}

/// Outcome of a cleanup pass. Mirrors `MoveResult`'s shape so the UI can
/// present "we did N things, X of them failed" the same way.
struct CleanupResult: Sendable, Equatable {
    var deleted: [EmptyFolderCandidate]
    var errors: [String]
    var hasIssues: Bool { !errors.isEmpty }
}

/// Pure-functional helpers for finding and removing empty source folders
/// after a successful apply.
///
/// The design is deliberately conservative: we only consider folders that
/// actually had a source file moved out of them, and we never touch the
/// base folder itself. That way an unrelated empty folder somewhere under
/// the job tree never gets pulled into the "ready to remove" list.
enum FolderCleanup {

    /// Items we treat as effectively "not there" when deciding whether a
    /// folder is empty. macOS sprinkles `.DS_Store` everywhere; an empty
    /// folder full of just that is still empty for our purposes.
    private static let ignorableNames: Set<String> = [".DS_Store"]

    /// Build the candidate list from a journal of completed moves. With
    /// multiple source roots in play, each source has its own "don't
    /// touch the root" guard and its own relative-path frame for display.
    /// A parent folder that doesn't sit under any of the supplied sources
    /// (rare, but possible if the operator removed a source mid-job)
    /// falls back to its own last path component for display.
    static func candidates(from moves: [Move], sourceFolders: [URL]) -> [EmptyFolderCandidate] {
        let stdRoots = sourceFolders.map { $0.standardizedFileURL }
        let rootSet = Set(stdRoots)
        var parents = Set<URL>()
        for move in moves {
            parents.insert(move.src.deletingLastPathComponent().standardizedFileURL)
        }
        // Never propose to delete one of the source roots itself, even if
        // an apply emptied it completely.
        parents.subtract(rootSet)

        var out: [EmptyFolderCandidate] = []
        for url in parents where isEmptyExceptIgnorable(url) {
            let rel = relativePath(of: url, under: stdRoots) ?? url.lastPathComponent
            out.append(EmptyFolderCandidate(url: url, relativePath: rel))
        }
        // Stable order so the UI doesn't flicker between runs.
        return out.sorted { $0.relativePath < $1.relativePath }
    }

    /// Relative path of `url` under whichever of `roots` contains it.
    /// Multi-source jobs prefix the source folder name so two empty
    /// folders called "Top Shelf" under different sources stay distinct.
    private static func relativePath(of url: URL, under roots: [URL]) -> String? {
        for root in roots where url.path.hasPrefix(root.path + "/") {
            let tail = String(url.path.dropFirst(root.path.count + 1))
            return roots.count > 1 ? "\(root.lastPathComponent)/\(tail)" : tail
        }
        return nil
    }

    /// True when the directory contains nothing, or only files we consider
    /// safe to silently delete alongside the folder.
    static func isEmptyExceptIgnorable(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        // `includingPropertiesForKeys: nil` and `skipsHiddenFiles: false`
        // because we want to see `.DS_Store` and friends so we can choose
        // to ignore them deliberately, not have the OS hide them from us.
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return false
        }
        return entries.allSatisfy { ignorableNames.contains($0.lastPathComponent) }
    }

    /// Remove the chosen candidates. Each candidate has any ignorable
    /// child files swept first so `removeItem` doesn't trip on them.
    static func cleanUp(_ candidates: [EmptyFolderCandidate]) -> CleanupResult {
        let fm = FileManager.default
        var deleted: [EmptyFolderCandidate] = []
        var errors: [String] = []
        for candidate in candidates {
            // Remove ignorable children first. We don't bail on errors here —
            // if `.DS_Store` won't go, the folder removal below will fail
            // with a clearer message and we'll surface that instead.
            for name in ignorableNames {
                let child = candidate.url.appendingPathComponent(name)
                try? fm.removeItem(at: child)
            }
            do {
                try fm.removeItem(at: candidate.url)
                deleted.append(candidate)
            } catch {
                errors.append("\(candidate.relativePath): \(error.localizedDescription)")
            }
        }
        return CleanupResult(deleted: deleted, errors: errors)
    }
}
