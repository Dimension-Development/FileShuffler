import Foundation

/// Side-effects the executor needs from the outside world. Kept as a struct
/// of `@Sendable` closures rather than a delegate protocol so the caller can
/// stand it up inline from a SwiftUI view, and we don't have to manage a
/// reference type's lifecycle. Both closures are async because the UI may
/// need to render between progress ticks and a collision dialog must wait
/// for the user.
struct MoveExecutorCallbacks: Sendable {
    var onProgress: @Sendable (MoveProgress) async -> Void
    var onCollision: @Sendable (Match, URL) async -> CollisionDecision

    static let silent = MoveExecutorCallbacks(
        onProgress: { _ in },
        onCollision: { _, _ in .skip(forAll: false) }
    )
}

/// Pure-ish, namespaced functions that perform and reverse transfers
/// (moves or copies, per `TransferMode`).
///
/// File coordination via `NSFileCoordinator` is used so the operating system
/// arbitrates with other apps that might have the file open (Finder previews,
/// Adobe Illustrator, Quick Look). Without it, a transfer from under a
/// presenter can leave stale state in the other app.
enum MoveExecutor {

    /// Apply a list of matches against `destinationFolder`. Each match
    /// becomes a transfer from its source URL (which may live under any of
    /// the operator's source folders) into
    /// `destinationFolder/<row.folderName>/<filename>`. Destination
    /// subfolders are created on demand. `mode` decides whether the source
    /// file is moved or copied; either way the journal records src → dst
    /// so Undo knows exactly what to reverse.
    static func apply(
        matches: [Match],
        destinationFolder: URL,
        mode: TransferMode,
        callbacks: MoveExecutorCallbacks
    ) async -> MoveResult {
        var moved: [Move] = []
        var skipped: [Match] = []
        var errors: [MoveError] = []
        var policy: CollisionPolicy = .ask
        var stoppedEarly = false

        await callbacks.onProgress(MoveProgress(total: matches.count, done: 0, current: ""))

        for (i, match) in matches.enumerated() {
            await callbacks.onProgress(
                MoveProgress(total: matches.count, done: i, current: match.source.relativePath)
            )

            let destDir = destinationFolder.appendingPathComponent(match.destination, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            } catch {
                errors.append(MoveError(match: match, message: error.localizedDescription))
                continue
            }

            // `destinationFilename` accounts for the optional quantity-suffix
            // rename (e.g. `foo.ai` -> `foo_x30.ai`). Source file is moved
            // and renamed in a single FS operation by the coordinator below.
            let destURL = destDir.appendingPathComponent(match.destinationFilename)

            // No-op when source and destination resolve to the same path —
            // this can happen if Apply is run twice without rescanning.
            if match.source.url.standardizedFileURL.path == destURL.standardizedFileURL.path {
                continue
            }

            if FileManager.default.fileExists(atPath: destURL.path) {
                let decision: CollisionDecision
                switch policy {
                case .ask:
                    decision = await callbacks.onCollision(match, destURL)
                case .skipAll:
                    decision = .skip(forAll: false)
                case .replaceAll:
                    decision = .replace(forAll: false)
                }

                switch decision {
                case .skip(let forAll):
                    if forAll { policy = .skipAll }
                    skipped.append(match)
                    continue
                case .replace(let forAll):
                    if forAll { policy = .replaceAll }
                    do {
                        try FileManager.default.removeItem(at: destURL)
                    } catch {
                        errors.append(MoveError(match: match, message: error.localizedDescription))
                        continue
                    }
                case .cancel:
                    stoppedEarly = true
                    await callbacks.onProgress(
                        MoveProgress(total: matches.count, done: i, current: "")
                    )
                    return MoveResult(
                        moved: moved, skipped: skipped, errors: errors, stoppedEarly: true
                    )
                }
            }

            do {
                switch mode {
                case .move: try coordinatedMove(from: match.source.url, to: destURL)
                case .copy: try coordinatedCopy(from: match.source.url, to: destURL)
                }
                moved.append(Move(src: match.source.url, dst: destURL))
            } catch {
                errors.append(MoveError(match: match, message: error.localizedDescription))
            }
        }

        await callbacks.onProgress(
            MoveProgress(total: matches.count, done: matches.count, current: "")
        )
        return MoveResult(
            moved: moved, skipped: skipped, errors: errors, stoppedEarly: stoppedEarly
        )
    }

    /// Reverse a journal of transfers. For `.move`, each file is moved back
    /// to its recorded source; for `.copy`, the source never changed so
    /// undoing simply deletes the duplicate we created at the destination.
    /// We walk in reverse so that, if anything went wrong mid-apply, undoing
    /// the latest transfer first reduces the chance of one undo step's
    /// destination clashing with a later one.
    static func undo(_ moves: [Move], mode: TransferMode) async -> UndoResult {
        var reverted: [Move] = []
        var errors: [String] = []

        for move in moves.reversed() {
            do {
                switch mode {
                case .move:
                    let parent = move.src.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                    try coordinatedMove(from: move.dst, to: move.src)
                case .copy:
                    try coordinatedDelete(at: move.dst)
                }
                reverted.append(move)
            } catch {
                errors.append("\(move.dst.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return UndoResult(reverted: reverted, errors: errors)
    }

    // MARK: - File coordination

    /// Synchronous coordinated move. `NSFileCoordinator.coordinate(writingItemAt:…)`
    /// runs the accessor inline; if the system can't acquire the locks it
    /// fills `coordError` and skips the accessor entirely. We thread two
    /// error slots through and re-throw whichever (if any) appeared.
    private static func coordinatedMove(from src: URL, to dst: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var moveError: Error?

        coordinator.coordinate(
            writingItemAt: src, options: [.forMoving],
            writingItemAt: dst, options: [.forReplacing],
            error: &coordError
        ) { newSrc, newDst in
            do {
                try FileManager.default.moveItem(at: newSrc, to: newDst)
            } catch {
                moveError = error
            }
        }

        if let coordError { throw coordError }
        if let moveError { throw moveError }
    }

    /// Synchronous coordinated copy. Reads the source (so a presenter can
    /// flush pending state first) while writing the destination.
    private static func coordinatedCopy(from src: URL, to dst: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var copyError: Error?

        coordinator.coordinate(
            readingItemAt: src, options: [],
            writingItemAt: dst, options: [.forReplacing],
            error: &coordError
        ) { newSrc, newDst in
            do {
                try FileManager.default.copyItem(at: newSrc, to: newDst)
            } catch {
                copyError = error
            }
        }

        if let coordError { throw coordError }
        if let copyError { throw copyError }
    }

    /// Synchronous coordinated delete, used to undo a copy.
    private static func coordinatedDelete(at url: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var deleteError: Error?

        coordinator.coordinate(
            writingItemAt: url, options: [.forDeleting],
            error: &coordError
        ) { target in
            do {
                try FileManager.default.removeItem(at: target)
            } catch {
                deleteError = error
            }
        }

        if let coordError { throw coordError }
        if let deleteError { throw deleteError }
    }
}
