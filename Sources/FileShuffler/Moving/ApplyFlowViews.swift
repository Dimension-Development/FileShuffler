import SwiftUI

/// Carrier for a paused move that's waiting on the user. Holds the
/// collision context the alert needs and the resume closure that hands
/// control back to the executor's `await`.
struct PendingCollision: Identifiable {
    let id = UUID()
    let match: Match
    let destination: URL
    let resume: (CollisionDecision) -> Void
}

// MARK: - Progress view

/// Shown while an apply (or undo) is in flight. Determinate progress with
/// the current item underneath, so the operator can see exactly which file
/// the system is touching.
struct ApplyProgressView: View {
    let title: String
    let progress: MoveProgress?
    let onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let p = progress {
                    Text("\(p.done) / \(p.total)").font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: progress?.fraction ?? 0)
            Text(progress?.current.isEmpty == false ? progress!.current : " ")
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onCancel {
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Result view

struct ApplyResultView: View {
    let result: MoveResult
    let undoResult: UndoResult?
    /// Empty source folders that the operator could clean up. `nil` while
    /// the post-apply scan hasn't completed; an empty array means nothing
    /// to clean.
    let cleanupCandidates: [EmptyFolderCandidate]?
    /// Result of the cleanup pass, once run.
    let cleanupResult: CleanupResult?
    let onUndo: () -> Void
    let onCleanup: (() -> Void)?
    let onExportLog: (() -> Void)?
    let onDone: () -> Void

    private var canUndo: Bool {
        undoResult == nil && !result.moved.isEmpty
    }

    private var canCleanUp: Bool {
        // Only available when there are candidates and we haven't already
        // cleaned. After undo, the source folders are no longer empty so
        // any pending candidates are stale and we hide the section.
        undoResult == nil
            && cleanupResult == nil
            && (cleanupCandidates?.isEmpty == false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            stats
            if let undoResult { undoSummary(undoResult) }
            if !result.skipped.isEmpty { skippedSection }
            if !result.errors.isEmpty { errorsSection }
            cleanupSection
            HStack {
                if let onExportLog {
                    Button("Export log…", action: onExportLog)
                }
                Spacer()
                if canUndo {
                    Button("Undo", role: .destructive, action: onUndo)
                }
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: undoResult != nil ? "arrow.uturn.backward.circle.fill" : (result.hasIssues ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"))
                .font(.title)
                .foregroundStyle(undoResult != nil ? .blue : (result.hasIssues ? .orange : .green))
            VStack(alignment: .leading) {
                Text(undoResult != nil ? "Undo finished" : (result.stoppedEarly ? "Apply cancelled" : "Apply finished"))
                    .font(.title3).bold()
                Text(undoResult != nil
                     ? "Files restored to their original locations."
                     : "Files moved to their destination folders.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var stats: some View {
        HStack(spacing: 20) {
            statTile(label: "Moved", value: "\(result.moved.count)", tint: .green)
            statTile(label: "Skipped", value: "\(result.skipped.count)", tint: result.skipped.isEmpty ? .secondary : .orange)
            statTile(label: "Errors", value: "\(result.errors.count)", tint: result.errors.isEmpty ? .secondary : .red)
        }
    }

    private func statTile(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.monospacedDigit()).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
    }

    private func undoSummary(_ undo: UndoResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Undo: \(undo.reverted.count) restored\(undo.errors.isEmpty ? "" : ", \(undo.errors.count) failed")")
                .font(.callout)
            if !undo.errors.isEmpty {
                ForEach(undo.errors, id: \.self) { e in
                    Text("• \(e)").font(.caption.monospaced()).foregroundStyle(.red)
                }
            }
        }
    }

    private var skippedSection: some View {
        DisclosureGroup("Skipped (\(result.skipped.count))") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(result.skipped, id: \.id) { s in
                    Text(s.source.relativePath).font(.caption.monospaced())
                }
            }.padding(.leading, 16)
        }
    }

    private var errorsSection: some View {
        DisclosureGroup("Errors (\(result.errors.count))") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(result.errors, id: \.match.id) { e in
                    Text("\(e.match.source.relativePath) — \(e.message)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                }
            }.padding(.leading, 16)
        }
    }

    @ViewBuilder
    private var cleanupSection: some View {
        if let cleanupResult {
            // After cleanup has run.
            cleanupSummaryView(cleanupResult)
        } else if canCleanUp, let candidates = cleanupCandidates, !candidates.isEmpty {
            // Available but not yet run.
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                        Text("Empty source folders").font(.headline)
                        Text("\(candidates.count)")
                            .font(.headline).foregroundStyle(.secondary)
                        Spacer()
                        if let onCleanup {
                            Button("Clean up", action: onCleanup)
                        }
                    }
                    Text("These folders had files moved out and are now empty (or only contain a `.DS_Store`).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DisclosureGroup("Show folders") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(candidates) { c in
                                Text(c.relativePath).font(.caption.monospaced())
                            }
                        }.padding(.leading, 16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func cleanupSummaryView(_ cleanup: CleanupResult) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: cleanup.hasIssues ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(cleanup.hasIssues ? .orange : .green)
                    Text("Cleaned up \(cleanup.deleted.count) empty folder\(cleanup.deleted.count == 1 ? "" : "s")")
                        .font(.callout)
                    Spacer()
                }
                if !cleanup.errors.isEmpty {
                    DisclosureGroup("Errors (\(cleanup.errors.count))") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(cleanup.errors, id: \.self) { e in
                                Text("• \(e)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.red)
                            }
                        }.padding(.leading, 16)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
