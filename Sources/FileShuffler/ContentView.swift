import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Where the apply flow currently is, in plain English. Drives which sheet,
/// progress, or summary the user sees. `.idle` means the plan view is the
/// active screen.
enum ApplyPhase: Equatable {
    case idle
    case applying
    case completed
    case undoing
    case undone
}

struct ContentView: View {
    /// Source roots the operator added — works orders sometimes hand the
    /// operator multiple server links pointing at different parts of the
    /// same job. Order is the order added (first = default destination).
    @State private var sourceFolders: [URL] = []
    /// Where moves land. Defaults to the first source added; can be
    /// re-pointed anywhere (other share, local disk) by the operator.
    @State private var destinationFolder: URL?

    @State private var sheetURL: URL?
    /// Every worksheet of the loaded workbook; `worksheetName` selects the
    /// active one. CSV/TSV files load as a single pseudo-sheet, so the
    /// worksheet picker only appears for multi-sheet .xlsx job sheets.
    @State private var workbookTables: [NamedTable] = []
    @State private var worksheetName: String = ""
    @State private var fileColumn: String = ""
    @State private var folderColumn: String = ""
    /// Sentinel "(none)" disables the quantity rename. Stored as the picker's
    /// selection so SwiftUI can bind to it like a normal column choice.
    @State private var quantityColumn: String = ContentView.noneTag
    /// Optional second artwork column ("Artwork name Back" on V1 job
    /// sheets). "(none)" disables it, same pattern as the quantity picker.
    @State private var backFileColumn: String = ContentView.noneTag
    /// Optional nested-destination column ("Colour Spec" on V1 job sheets):
    /// files land in <Folder>/<Subfolder> when set.
    @State private var subfolderColumn: String = ContentView.noneTag

    /// The active worksheet's table, if any.
    private var sheetTable: SpreadsheetTable? {
        workbookTables.first { $0.name == worksheetName }?.table
    }
    @State private var files: [SourceFile] = []
    @State private var plan: MatchPlan?
    /// Operator's pick per conflicted row (key = `MappingRow.id`). Persists
    /// across plan rebuilds so editing column choices doesn't blow away
    /// resolutions; `reset` and `loadProject` reset it explicitly.
    @State private var conflictResolutions: [Int: MatchEngine.ConflictResolution] = [:]
    @State private var error: String?

    static let noneTag = "(none)"

    /// The app copies files rather than moving them: originals stay in the
    /// source folders, and Undo deletes the copies. `MoveExecutor` still
    /// supports `.move` (kept implemented and tested) should a per-job
    /// toggle ever be wanted.
    private static let transferMode: TransferMode = .copy

    // M1 — apply / undo flow state
    @State private var applyPhase: ApplyPhase = .idle
    @State private var applyProgress: MoveProgress?
    @State private var applyResult: MoveResult?
    @State private var undoResult: UndoResult?
    @State private var pendingCollision: PendingCollision?
    @State private var confirmingApply = false
    @State private var applyStartedAt: Date?
    @State private var auditLog: AuditLog?

    // M2 — project save / load state
    @State private var currentProjectURL: URL?

    // M2 — empty-folder cleanup state
    @State private var cleanupCandidates: [EmptyFolderCandidate]?
    @State private var cleanupResult: CleanupResult?

    // M3 — paste-link / clipboard-suggestion state. Two paste fields now:
    // one for adding sources (additive), one for setting the destination
    // (single value). The clipboard banner only suggests sources, since
    // works-order links are the source paths.
    @State private var pastedSource: String = ""
    @State private var pastedDestination: String = ""
    @State private var clipboardSuggestion: ClipboardSuggestion?
    /// Operator dismissed the banner — don't re-show until app relaunch.
    @State private var clipboardBannerDismissed: Bool = false
    /// Previous pasteboard `changeCount` so we can ignore a clipboard whose
    /// contents we've already evaluated (and possibly dismissed).
    @State private var lastClipboardChangeCount: Int = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            if clipboardSuggestion != nil && !clipboardBannerDismissed {
                clipboardBanner
            }
            inputs
            Divider()
            content
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            footer
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 600)
        .onAppear { refreshClipboardSuggestion() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshClipboardSuggestion()
        }
        .alert(
            "Copy \(plan?.matched.count ?? 0) files?",
            isPresented: $confirmingApply,
            presenting: plan
        ) { _ in
            Button("Copy", action: startApply)
            Button("Cancel", role: .cancel, action: {})
        } message: { _ in
            Text("Files will be copied from their source locations into the destination folders shown in the plan, under \(destinationFolder?.lastPathComponent ?? "the destination folder"). The originals stay where they are. Files not listed in the sheet are not copied.")
        }
        .alert(
            "“\(pendingCollision?.destination.lastPathComponent ?? "")” already exists",
            isPresented: collisionAlertBinding,
            presenting: pendingCollision
        ) { collision in
            Button("Skip") { collision.resume(.skip(forAll: false)) }
            Button("Skip all") { collision.resume(.skip(forAll: true)) }
            Button("Replace", role: .destructive) { collision.resume(.replace(forAll: false)) }
            Button("Replace all", role: .destructive) { collision.resume(.replace(forAll: true)) }
            Button("Cancel apply", role: .cancel) { collision.resume(.cancel) }
        } message: { collision in
            Text("A file with the same name is already in “\(collision.match.destination)”. What would you like to do?")
        }
        .sheet(isPresented: applySheetBinding) {
            applySheetContent
        }
    }

    // MARK: - Footer

    /// Apply requires at least one match, a destination, and zero unresolved
    /// conflicts. Conflicts are deliberately hard-blocking — silent picks
    /// here would defeat the whole point of the app.
    private var canApply: Bool {
        guard let plan, !plan.matched.isEmpty, destinationFolder != nil else {
            return false
        }
        return plan.conflicts.isEmpty
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Copy files") {
                confirmingApply = true
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canApply)
        }
    }

    // MARK: - Apply sheet content

    @ViewBuilder
    private var applySheetContent: some View {
        switch applyPhase {
        case .applying:
            ApplyProgressView(
                title: "Copying files…",
                progress: applyProgress,
                onCancel: nil    // collision dialog already offers Cancel apply
            )
        case .undoing:
            ApplyProgressView(
                title: "Removing copies…",
                progress: applyProgress,
                onCancel: nil
            )
        case .completed, .undone:
            if let result = applyResult {
                ApplyResultView(
                    result: result,
                    undoResult: undoResult,
                    cleanupCandidates: cleanupCandidates,
                    cleanupResult: cleanupResult,
                    onUndo: startUndo,
                    onCleanup: startCleanup,
                    // Only offer Export log when there's a log to export —
                    // i.e. after a real apply, before an Undo wipes it back.
                    onExportLog: auditLog != nil ? exportAuditLog : nil,
                    // Sizes report needs the destination files in place,
                    // so the button hides after Undo too.
                    onExportSizes: canExportSizes ? exportSizesReport : nil,
                    onDone: finishApplyFlow
                )
            } else {
                EmptyView()
            }
        case .idle:
            EmptyView()
        }
    }

    private var applySheetBinding: Binding<Bool> {
        Binding(
            get: { applyPhase != .idle },
            set: { open in
                if !open && (applyPhase == .completed || applyPhase == .undone) {
                    finishApplyFlow()
                }
            }
        )
    }

    private var collisionAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingCollision != nil },
            set: { open in
                if !open, let pending = pendingCollision {
                    // Esc / dismissal without a button press — treat as cancel
                    // so the executor doesn't hang on the continuation.
                    pending.resume(.cancel)
                }
            }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("File Shuffler").font(.title2).bold()
            if let url = currentProjectURL {
                Text("· \(url.lastPathComponent)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Cmd-O / Cmd-S work even without File menu items because the
            // shortcuts attach to the focused window's button.
            Button("Open…", action: openProject)
                .keyboardShortcut("o", modifiers: .command)
            Button("Save…", action: saveProject)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(sourceFolders.isEmpty || destinationFolder == nil || sheetURL == nil)
            if plan != nil {
                Button("New job", action: reset)
            }
        }
    }

    // MARK: - Inputs

    private var inputs: some View {
        VStack(alignment: .leading, spacing: 10) {
            SourcesSection(
                sources: sourceFolders,
                pasted: $pastedSource,
                onSubmit: { Task { await resolveAndAddSource(from: pastedSource) } },
                onBrowse: pickSourceFolder,
                onURL: { url in Task { await resolveAndAddSource(from: url.path) } },
                onRemove: removeSource
            )
            DestinationRow(
                destination: destinationFolder,
                pasted: $pastedDestination,
                onSubmit: { Task { await resolveAndSetDestination(from: pastedDestination) } },
                onBrowse: pickDestinationFolder,
                onURL: { url in Task { await resolveAndSetDestination(from: url.path) } }
            )
            DropTarget(
                title: "Spreadsheet",
                value: sheetURL?.lastPathComponent ?? "Drop an .xlsx, .csv, or .tsv here",
                systemImage: "tablecells",
                trailing: { Button("Browse…", action: pickSheet) },
                onURL: setSheet
            )
            if !workbookTables.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if workbookTables.count > 1 {
                        HStack(spacing: 8) {
                            Text("Worksheet").foregroundStyle(.secondary)
                            Picker("", selection: $worksheetName) {
                                ForEach(workbookTables, id: \.name) { Text($0.name).tag($0.name) }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 240)
                            .help("Which tab of the workbook holds the job table. Auto-picked by looking for recognisable columns — override if it guessed wrong.")
                            Spacer()
                        }
                        .onChange(of: worksheetName) {
                            // A different sheet means different headers —
                            // re-detect rather than carry stale choices over.
                            applyDetectedColumns()
                            rebuildPlan()
                        }
                    }
                    if let table = sheetTable {
                        let options = columnOptions(table)
                        HStack(spacing: 16) {
                            columnPicker(label: "File column", selection: $fileColumn, options: options)
                            columnPicker(
                                label: "Back file column",
                                selection: $backFileColumn,
                                options: [Self.noneTag] + options,
                                help: "Optional second artwork column (e.g. 'Artwork name Back'). Rows with a value there produce an extra file, copied to the same folder."
                            )
                            columnPicker(
                                label: "Quantity column",
                                selection: $quantityColumn,
                                options: [Self.noneTag] + options,
                                help: "Optional. When set, files are renamed with a _xN suffix using the quantity from each row."
                            )
                            Spacer()
                        }
                        HStack(spacing: 16) {
                            columnPicker(label: "Folder column", selection: $folderColumn, options: options)
                            columnPicker(
                                label: "Subfolder column",
                                selection: $subfolderColumn,
                                options: [Self.noneTag] + options,
                                help: "Optional. Files are copied into <Folder>/<Subfolder> — e.g. Material/Colour Spec."
                            )
                            Spacer()
                        }
                        .onChange(of: fileColumn) { rebuildPlan() }
                        .onChange(of: folderColumn) { rebuildPlan() }
                        .onChange(of: quantityColumn) { rebuildPlan() }
                        .onChange(of: backFileColumn) { rebuildPlan() }
                        .onChange(of: subfolderColumn) { rebuildPlan() }
                    }
                }
            }
        }
    }

    private func columnPicker(
        label: String,
        selection: Binding<String>,
        options: [String],
        help: String? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 240)
            .help(help ?? "")
        }
    }

    // MARK: - Plan view

    @ViewBuilder
    private var content: some View {
        if let plan {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    matchedSection(plan)
                    if !plan.conflicts.isEmpty {
                        conflictsSection(plan)
                    }
                    sheetOrphansSection(plan)
                    fileOrphansSection(plan)
                }
            }
        } else {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Add a source folder, a destination, and a spreadsheet to see the plan.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            Spacer()
        }
    }

    /// Toggle prefix display only when there's more than one source — the
    /// extra prefix is just visual noise on single-source jobs.
    private var showsBaseFolderPrefix: Bool { sourceFolders.count > 1 }

    private func matchedSection(_ plan: MatchPlan) -> some View {
        let grouped = Dictionary(grouping: plan.matched, by: { $0.destination })
        return planSection(title: "Matched — will copy", count: plan.matched.count, tint: .green) {
            if grouped.isEmpty {
                Text("Nothing matched yet.").foregroundStyle(.secondary)
            } else {
                ForEach(grouped.keys.sorted(), id: \.self) { dest in
                    let matches = grouped[dest] ?? []
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(matches, id: \.id) { m in
                                HStack(spacing: 8) {
                                    Image(systemName: m.normalised ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                        .foregroundStyle(m.normalised ? .orange : .green)
                                        .help(m.normalised ? "Match required normalisation (e.g. extra whitespace)" : "Exact match")
                                    Text(m.source.displayPath(showingBase: showsBaseFolderPrefix))
                                        .font(.callout.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if m.willRename {
                                        // Surface the rename so the operator
                                        // can sanity-check the _xN suffix.
                                        Image(systemName: "arrow.right")
                                            .foregroundStyle(.secondary)
                                            .font(.caption)
                                        Text(m.destinationFilename)
                                            .font(.callout.monospaced())
                                            .foregroundStyle(.blue)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                        }
                        .padding(.leading, 16)
                    } label: {
                        HStack {
                            Text(dest).font(.callout).bold()
                            Text("\(matches.count)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func conflictsSection(_ plan: MatchPlan) -> some View {
        planSection(
            title: "Conflicts — pick one per row",
            count: plan.conflicts.count,
            tint: .red
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(plan.conflicts) { conflict in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(conflict.row.fileName).font(.callout.monospaced())
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Text(conflict.row.folderName).font(.callout)
                            Spacer()
                            Button("Skip this row") {
                                resolveConflict(rowID: conflict.row.id, with: .skip)
                            }
                            .controlSize(.small)
                        }
                        ForEach(conflict.candidates, id: \.id) { candidate in
                            Button {
                                resolveConflict(
                                    rowID: conflict.row.id,
                                    with: .use(candidate.url)
                                )
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "circle")
                                        .foregroundStyle(.secondary)
                                    Text(candidate.displayPath(showingBase: showsBaseFolderPrefix))
                                        .font(.callout.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 16)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }

    private func sheetOrphansSection(_ plan: MatchPlan) -> some View {
        planSection(title: "Sheet rows with no file on disk", count: plan.sheetRowsWithoutFile.count, tint: .orange) {
            if plan.sheetRowsWithoutFile.isEmpty {
                Text("None.").foregroundStyle(.secondary)
            } else {
                ForEach(plan.sheetRowsWithoutFile, id: \.id) { r in
                    HStack {
                        Text(r.fileName).font(.callout.monospaced())
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(r.folderName).font(.callout)
                        Spacer()
                    }
                }
            }
        }
    }

    private func fileOrphansSection(_ plan: MatchPlan) -> some View {
        planSection(title: "Files not in sheet", count: plan.filesNotInSheet.count, tint: .red) {
            if plan.filesNotInSheet.isEmpty {
                Text("None.").foregroundStyle(.secondary)
            } else {
                ForEach(plan.filesNotInSheet, id: \.id) { f in
                    Text(f.displayPath(showingBase: showsBaseFolderPrefix))
                        .font(.callout.monospaced())
                }
            }
        }
    }

    @ViewBuilder
    private func planSection<Content: View>(title: String, count: Int, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(tint).frame(width: 8, height: 8)
                    Text(title).font(.headline)
                    Text("\(count)").font(.headline).foregroundStyle(.secondary)
                    Spacer()
                }
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Actions

    private func reset() {
        sourceFolders = []
        destinationFolder = nil
        sheetURL = nil
        workbookTables = []
        worksheetName = ""
        fileColumn = ""
        folderColumn = ""
        quantityColumn = Self.noneTag
        backFileColumn = Self.noneTag
        subfolderColumn = Self.noneTag
        files = []
        plan = nil
        conflictResolutions = [:]
        error = nil
        currentProjectURL = nil
        auditLog = nil
        applyStartedAt = nil
        cleanupCandidates = nil
        cleanupResult = nil
    }

    private func pickSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await applyAddSource(url) }
        }
    }

    private func pickDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            setDestination(url)
        }
    }

    // MARK: - Paste-link / clipboard suggestion

    /// Banner shown above the inputs when the pasteboard contains a path
    /// the source-policy parser accepts. The operator can accept it (zero
    /// clicks after launch), dismiss it for this session, or just ignore
    /// it and type into the paste field directly. Banner only suggests
    /// sources because works-order links are always source paths.
    private var clipboardBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Add source folder from clipboard?")
                    .font(.callout).bold()
                Text(clipboardSuggestion?.folderName ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Add as source") {
                Task { await acceptClipboardSuggestion() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
            Button("Dismiss") {
                clipboardBannerDismissed = true
                clipboardSuggestion = nil
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
        )
    }

    /// Read the pasteboard, run it through the source-policy parser, and
    /// surface a suggestion when it's something we can act on. Filters out
    /// the share root itself and other shallow paths so we don't pester
    /// the operator with "use folder DimensionHub?".
    private func refreshClipboardSuggestion() {
        if clipboardBannerDismissed { return }
        let pb = NSPasteboard.general
        // Skip work when the clipboard hasn't changed since last check —
        // re-evaluating the same string can't produce a new suggestion.
        guard pb.changeCount != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = pb.changeCount

        guard let raw = pb.string(forType: .string) else {
            clipboardSuggestion = nil
            return
        }
        let candidate: URL
        switch PathNormaliser.parseSource(raw) {
        case .onShare(let url): candidate = url
        case .local(let url):   candidate = url
        case .wrongShare, .unrecognised:
            clipboardSuggestion = nil
            return
        }
        // /Volumes/DimensionHub/<one-segment> is 4 path components in URL
        // terms ("/", "Volumes", "DimensionHub", segment) — anything
        // shallower than that is almost certainly not a real job folder.
        guard candidate.pathComponents.count >= 4 else {
            clipboardSuggestion = nil
            return
        }
        clipboardSuggestion = ClipboardSuggestion(
            raw: raw,
            folderName: candidate.lastPathComponent
        )
    }

    private func acceptClipboardSuggestion() async {
        guard let suggestion = clipboardSuggestion else { return }
        clipboardSuggestion = nil
        await resolveAndAddSource(from: suggestion.raw)
    }

    /// Source-side entry point. Used by the paste field, the clipboard
    /// banner accept button, and the drop target. Routes through
    /// `parseSource`, attempts to mount DimensionHub if needed, and
    /// silently falls back to the parent folder when the string pointed
    /// at a file (informing the operator inline).
    @MainActor
    private func resolveAndAddSource(from raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch PathNormaliser.parseSource(trimmed) {
        case .unrecognised:
            error = "Couldn't make sense of that path. Paste a folder link from the works order, drop a folder here, or click Browse."
        case .wrongShare(let name):
            error = "“\(name)” isn't a share I work with. Sources must be under DimensionHub or local folders. (Destinations can be anywhere.)"
        case .local(let url), .onShare(let url):
            if case .onShare = PathNormaliser.parseSource(trimmed) {
                if !FileManager.default.fileExists(atPath: "/Volumes/" + PathNormaliser.canonicalShare) {
                    do {
                        try await NetFSMounter.ensureCanonicalShareMounted()
                    } catch {
                        self.error = "Couldn't connect to the DimensionHub server. Open it once in Finder, then try again."
                        return
                    }
                }
            }
            await applyAddSource(url)
        }
    }

    /// Destination-side entry point. Same shape as the source resolver,
    /// but uses the permissive `parseDestination` since the operator may
    /// route output anywhere — including other shares.
    @MainActor
    private func resolveAndSetDestination(from raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch PathNormaliser.parseDestination(trimmed) {
        case .unrecognised:
            error = "Couldn't make sense of that path. Paste a folder link, drop a folder here, or click Browse."
        case .ok(let url):
            // Only auto-mount the canonical share — other shares the
            // operator must mount themselves via Finder, since we don't
            // have credentials for them.
            if url.path.hasPrefix("/Volumes/" + PathNormaliser.canonicalShare),
               !FileManager.default.fileExists(atPath: "/Volumes/" + PathNormaliser.canonicalShare) {
                do {
                    try await NetFSMounter.ensureCanonicalShareMounted()
                } catch {
                    self.error = "Couldn't connect to the DimensionHub server. Open it once in Finder, then try again."
                    return
                }
            }
            await applySetDestination(url)
        }
    }

    /// Validate the chosen URL exists, fall back to its parent if it
    /// points at a file, then append it to `sourceFolders` (refusing
    /// duplicates so the operator can't accidentally scan one tree
    /// twice). Auto-sets the destination to the new source if it's the
    /// first one — a no-op for subsequent additions.
    @MainActor
    private func applyAddSource(_ url: URL) async {
        guard let folder = await resolvedFolder(at: url) else { return }
        let std = folder.standardizedFileURL.resolvingSymlinksInPath()
        if sourceFolders.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == std }) {
            error = "“\(folder.lastPathComponent)” is already in the sources list."
            return
        }
        sourceFolders.append(std)
        if destinationFolder == nil {
            destinationFolder = std
        }
        pastedSource = ""
        rescan()
    }

    /// Single-value setter for the destination. Same file→folder fallback
    /// as the source resolver.
    @MainActor
    private func applySetDestination(_ url: URL) async {
        guard let folder = await resolvedFolder(at: url) else { return }
        destinationFolder = folder.standardizedFileURL.resolvingSymlinksInPath()
        pastedDestination = ""
        // Destination doesn't affect the scan or match plan — only the
        // apply step uses it — so no rescan needed.
        if error?.contains("doesn't exist") == true { error = nil }
    }

    /// File-vs-folder normalisation shared by the source and destination
    /// pipelines. Returns `nil` if the path doesn't exist on disk; sets
    /// `error` on the way out so the caller can simply early-return.
    @MainActor
    private func resolvedFolder(at url: URL) async -> URL? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            error = "“\(url.lastPathComponent)” doesn't exist on disk."
            return nil
        }
        if isDir.boolValue {
            error = nil
            return url
        }
        let parent = url.deletingLastPathComponent()
        error = "That link pointed at a file. Using the parent folder “\(parent.lastPathComponent)”."
        return parent
    }

    private func removeSource(_ url: URL) {
        sourceFolders.removeAll { $0 == url }
        // If the removed source was also the destination, pick the next
        // remaining source as a fallback (or clear destination if none).
        if destinationFolder == url {
            destinationFolder = sourceFolders.first
        }
        // Conflict resolutions referencing a removed source's files will
        // fall back to "no resolution" naturally on rebuild — those rows
        // re-appear as conflicts (or as solo matches if only one
        // candidate remains).
        rescan()
    }

    private func setDestination(_ url: URL) {
        destinationFolder = url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func pickSheet() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.commaSeparatedText, .tabSeparatedText]
        if let xlsx = UTType(filenameExtension: "xlsx") { types.append(xlsx) }
        panel.allowedContentTypes = types
        if panel.runModal() == .OK, let url = panel.url { setSheet(url) }
    }

    private func setSheet(_ url: URL) {
        sheetURL = url
        do {
            let tables = try SpreadsheetReader.readWorkbook(url)
            workbookTables = tables
            // Best-scoring worksheet wins (the V1 job sheet's table lives on
            // "Print & Laser", not the "Cover" tab); operator can override.
            worksheetName = SpreadsheetReader.bestTable(in: tables)?.name ?? ""
            applyDetectedColumns()
            error = nil
            rescan()
            // V1 job sheets carry the artwork folder as a server link in the
            // banner ("ARTWORK AT:" row) — feed it straight into the sources
            // so a dropped job sheet sets the whole job up by itself.
            if let links = sheetTable?.sourceLinks, !links.isEmpty {
                Task { await autoAddSheetSources(links) }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Add the job sheet's own artwork links as sources. Runs through the
    /// same parse → mount → validate pipeline as a manual paste, but with
    /// gentler failure handling: a link that's already a source is skipped
    /// silently, and a broken link becomes an inline note rather than
    /// blocking the sheet load.
    @MainActor
    private func autoAddSheetSources(_ links: [String]) async {
        for raw in links {
            switch PathNormaliser.parseSource(raw) {
            case .unrecognised:
                error = "The job sheet's artwork link couldn't be understood — add the source folder manually."
            case .wrongShare(let name):
                error = "The job sheet's artwork link points at “\(name)”, which isn't a share I work with — add the source folder manually."
            case .local(let url), .onShare(let url):
                if case .onShare = PathNormaliser.parseSource(raw),
                   !FileManager.default.fileExists(atPath: "/Volumes/" + PathNormaliser.canonicalShare) {
                    do {
                        try await NetFSMounter.ensureCanonicalShareMounted()
                    } catch {
                        self.error = "Found the artwork link in the job sheet, but couldn't connect to the DimensionHub server. Open it once in Finder, then add the source manually."
                        continue
                    }
                }
                let std = url.standardizedFileURL.resolvingSymlinksInPath()
                if sourceFolders.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == std }) {
                    continue    // already a source — nothing to report
                }
                await applyAddSource(url)
            }
        }
    }

    /// Run column autodetection against the active worksheet and apply the
    /// results — on sheet load and whenever the operator switches worksheet.
    /// Undetected optional roles fall back to "(none)"; the operator can
    /// override any pick.
    private func applyDetectedColumns() {
        guard let table = sheetTable else { return }
        let options = columnOptions(table)
        let detected = table.detectColumns()
        fileColumn = detected.file ?? options.first ?? ""
        folderColumn = detected.folder ?? (options.dropFirst().first ?? "")
        quantityColumn = detected.quantity ?? Self.noneTag
        backFileColumn = detected.backFile ?? Self.noneTag
        subfolderColumn = detected.subfolder ?? Self.noneTag
    }

    /// Headers usable as picker options: blanks dropped (job-sheet tables
    /// don't start in column A, so the header row leads with empty pads)
    /// and duplicates removed so SwiftUI's ForEach ids stay unique.
    private func columnOptions(_ table: SpreadsheetTable) -> [String] {
        var seen = Set<String>()
        return table.headers.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func rescan() {
        guard !sourceFolders.isEmpty else {
            files = []
            plan = nil
            return
        }
        do {
            let exclude: Set<URL> = sheetURL.map { [$0.standardizedFileURL.resolvingSymlinksInPath()] } ?? []
            files = try FolderScanner.scan(bases: sourceFolders, excluding: exclude)
            rebuildPlan()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func rebuildPlan() {
        guard let table = sheetTable, !fileColumn.isEmpty, !folderColumn.isEmpty else {
            plan = nil
            return
        }
        do {
            func chosen(_ column: String) -> String? {
                column == Self.noneTag ? nil : column
            }
            let rows = try table.mappingRows(
                fileColumn: fileColumn,
                folderColumn: folderColumn,
                quantityColumn: chosen(quantityColumn),
                backFileColumn: chosen(backFileColumn),
                subfolderColumn: chosen(subfolderColumn)
            )
            plan = MatchEngine.plan(
                files: files, rows: rows,
                resolutions: conflictResolutions
            )
            error = nil
        } catch {
            plan = nil
            self.error = error.localizedDescription
        }
    }

    private func resolveConflict(rowID: Int, with resolution: MatchEngine.ConflictResolution) {
        conflictResolutions[rowID] = resolution
        rebuildPlan()
    }

    // MARK: - Apply / Undo

    private func startApply() {
        guard let destinationFolder, let plan, !plan.matched.isEmpty else { return }
        let matches = plan.matched
        let sources = sourceFolders
        applyPhase = .applying
        applyProgress = MoveProgress(total: matches.count, done: 0, current: "")
        applyResult = nil
        undoResult = nil
        applyStartedAt = Date()        // captured here so the audit log
                                       // reflects when the apply *began*,
                                       // not when it finished.
        auditLog = nil
        cleanupCandidates = nil
        cleanupResult = nil

        Task {
            // Callbacks bridge the executor's async loop to the main actor's
            // SwiftUI state. Progress is fire-and-forget; collision suspends
            // until the user picks an option.
            let callbacks = MoveExecutorCallbacks(
                onProgress: { progress in
                    await MainActor.run { applyProgress = progress }
                },
                onCollision: { match, dst in
                    await requestCollisionDecision(match: match, destination: dst)
                }
            )
            let result = await MoveExecutor.apply(
                matches: matches,
                destinationFolder: destinationFolder,
                mode: Self.transferMode,
                callbacks: callbacks
            )
            await MainActor.run {
                applyResult = result
                if let started = applyStartedAt {
                    auditLog = AuditLog(
                        from: result,
                        startedAt: started,
                        sourceFolders: sources,
                        destinationFolder: destinationFolder,
                        sheetURL: sheetURL,
                        mode: Self.transferMode
                    )
                }
                // Empty-folder cleanup only makes sense for moves — a copy
                // leaves every source file in place, so scanning for newly
                // emptied folders would be wasted IO that finds nothing.
                cleanupCandidates = Self.transferMode == .move
                    ? FolderCleanup.candidates(from: result.moved, sourceFolders: sources)
                    : nil
                applyPhase = .completed
            }
        }
    }

    private func requestCollisionDecision(match: Match, destination: URL) async -> CollisionDecision {
        await withCheckedContinuation { (continuation: CheckedContinuation<CollisionDecision, Never>) in
            Task { @MainActor in
                pendingCollision = PendingCollision(
                    match: match,
                    destination: destination,
                    resume: { decision in
                        // Hop back to the main actor to clear state safely
                        // before resuming — otherwise the executor can race
                        // ahead and emit progress before the alert dismisses.
                        Task { @MainActor in
                            pendingCollision = nil
                            continuation.resume(returning: decision)
                        }
                    }
                )
            }
        }
    }

    private func startUndo() {
        guard let result = applyResult else { return }
        let moves = result.moved
        applyPhase = .undoing
        applyProgress = MoveProgress(total: moves.count, done: 0, current: "")

        Task {
            let undo = await MoveExecutor.undo(moves, mode: Self.transferMode)
            await MainActor.run {
                undoResult = undo
                applyPhase = .undone
            }
        }
    }

    /// Close the apply/undo sheet and refresh the plan against the new state
    /// of the disk. Copying leaves the sources untouched, but a rescan keeps
    /// the plan honest when the destination overlaps a source folder (the
    /// default when the destination wasn't re-pointed).
    /// `auditLog` is preserved so the operator can still export it from a
    /// saved project file later, but `applyResult` is cleared since the
    /// in-memory undo journal is no longer valid.
    private func finishApplyFlow() {
        applyPhase = .idle
        applyProgress = nil
        applyResult = nil
        undoResult = nil
        rescan()
    }

    // MARK: - Empty-folder cleanup

    private func startCleanup() {
        guard let candidates = cleanupCandidates, !candidates.isEmpty else { return }
        let result = FolderCleanup.cleanUp(candidates)
        cleanupResult = result
        // Mirror the cleanup into the audit log so an exported report shows
        // the operator both moved AND removed folders.
        auditLog?.cleanedUpFolders = result.deleted.map(\.relativePath)
    }

    // MARK: - Project save / load

    private func saveProject() {
        guard !sourceFolders.isEmpty, let destinationFolder, let sheetURL else { return }
        let panel = NSSavePanel()
        if let xt = UTType(filenameExtension: "shuffle") {
            panel.allowedContentTypes = [xt]
        }
        panel.nameFieldStringValue = currentProjectURL?.deletingPathExtension().lastPathComponent
            ?? destinationFolder.lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let project = ShuffleProject(
            sourceFolderPaths: sourceFolders.map(\.path),
            destinationPath: destinationFolder.path,
            sheetPath: sheetURL.path,
            fileColumn: fileColumn,
            folderColumn: folderColumn,
            quantityColumn: quantityColumn == Self.noneTag ? nil : quantityColumn,
            worksheetName: worksheetName.isEmpty ? nil : worksheetName,
            backFileColumn: backFileColumn == Self.noneTag ? nil : backFileColumn,
            subfolderColumn: subfolderColumn == Self.noneTag ? nil : subfolderColumn,
            conflictResolutions: serialiseResolutions(conflictResolutions),
            auditLog: auditLog
        )
        do {
            try ShuffleProjectIO.save(project, to: url)
            currentProjectURL = url
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func openProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if let xt = UTType(filenameExtension: "shuffle") {
            panel.allowedContentTypes = [xt]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadProject(from: url)
    }

    private func loadProject(from url: URL) {
        do {
            let project = try ShuffleProjectIO.load(from: url)
            // Restore inputs first, then load the spreadsheet so column
            // pickers populate before we apply the saved column choices.
            let restoredSheet = URL(fileURLWithPath: project.sheetPath)
            sheetURL = restoredSheet
            let tables = try SpreadsheetReader.readWorkbook(restoredSheet)
            workbookTables = tables
            // Saved worksheet wins when it still exists; otherwise fall back
            // to the reader's pick (sheet renamed or file replaced).
            if let saved = project.worksheetName, tables.contains(where: { $0.name == saved }) {
                worksheetName = saved
            } else {
                worksheetName = SpreadsheetReader.bestTable(in: tables)?.name ?? ""
            }
            fileColumn = project.fileColumn
            folderColumn = project.folderColumn
            quantityColumn = project.quantityColumn ?? Self.noneTag
            backFileColumn = project.backFileColumn ?? Self.noneTag
            subfolderColumn = project.subfolderColumn ?? Self.noneTag
            sourceFolders = project.sourceFolderPaths.map { URL(fileURLWithPath: $0) }
            destinationFolder = URL(fileURLWithPath: project.destinationPath)
            conflictResolutions = deserialiseResolutions(project.conflictResolutions)
            auditLog = project.auditLog
            currentProjectURL = url
            error = nil
            rescan()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Resolution (de)serialisation

    /// Convert the in-memory `[Int: ConflictResolution]` to the JSON-friendly
    /// `[String: ResolutionRecord]` shape stored in `.shuffle` files.
    private func serialiseResolutions(_ res: [Int: MatchEngine.ConflictResolution]) -> [String: ResolutionRecord] {
        var out: [String: ResolutionRecord] = [:]
        for (id, value) in res {
            switch value {
            case .skip:
                out[String(id)] = ResolutionRecord(kind: "skip", chosenPath: nil)
            case .use(let url):
                out[String(id)] = ResolutionRecord(kind: "use", chosenPath: url.path)
            }
        }
        return out
    }

    private func deserialiseResolutions(_ res: [String: ResolutionRecord]) -> [Int: MatchEngine.ConflictResolution] {
        var out: [Int: MatchEngine.ConflictResolution] = [:]
        for (key, record) in res {
            guard let id = Int(key) else { continue }
            switch record.kind {
            case "skip": out[id] = .skip
            case "use":
                if let path = record.chosenPath {
                    out[id] = .use(URL(fileURLWithPath: path))
                }
            default: continue
            }
        }
        return out
    }

    // MARK: - Audit log export

    private func exportAuditLog() {
        guard let log = auditLog else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = defaultLogFilename(for: log)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = log.plainTextReport()
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            error = nil
        } catch {
            self.error = "Could not write log: \(error.localizedDescription)"
        }
    }

    private func defaultLogFilename(for log: AuditLog) -> String {
        // e.g. "261144 — File Shuffler log — 2026-05-09.txt"
        let folderName = (log.destinationPath as NSString).lastPathComponent
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return "\(folderName) — File Shuffler log — \(df.string(from: log.finishedAt))"
    }

    // MARK: - Sizes report (PDF page dimensions)

    /// True when the report would have something to say: a PDF/AI in the
    /// journal that hasn't been undone away, or a sheet row whose file was
    /// never found (those export too, highlighted). Used to decide whether
    /// to show the Export sizes button at all.
    private var canExportSizes: Bool {
        guard undoResult == nil, let result = applyResult else { return false }
        return result.moved.contains(where: Self.isPDFLike)
            || !(plan?.sheetRowsWithoutFile.isEmpty ?? true)
    }

    /// Extract page dimensions from every PDF/AI in the journal and write
    /// the report. Extraction happens on click (not at apply time) so the
    /// apply itself stays snappy on jobs where this report isn't needed.
    /// Relative paths in the report are anchored to the destination —
    /// that's where the moved files now live.
    ///
    /// Written as .xlsx (not CSV) so sheet rows whose file was never found
    /// can ride along colour-highlighted; `plan` still holds the plan the
    /// apply ran from, so its unmatched rows are exactly the right list.
    private func exportSizesReport() {
        guard let destinationFolder, let result = applyResult else { return }
        let pdfURLs = result.moved
            .filter(Self.isPDFLike)
            .map(\.dst)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.xlsxType]
        panel.nameFieldStringValue = defaultSizesFilename()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let extracted = PDFSizeExtractor.extract(from: pdfURLs)
        let report = SizesReport(
            baseFolder: destinationFolder,
            files: extracted,
            missing: plan?.sheetRowsWithoutFile ?? []
        )
        do {
            try report.xlsx().write(to: url, options: .atomic)
            error = nil
        } catch {
            self.error = "Could not write sizes report: \(error.localizedDescription)"
        }
    }

    /// UTType for .xlsx. macOS ships the declaration (owned by Excel's
    /// exported type), so the lookup can't realistically fail; `.data` is
    /// a save-panel-safe fallback rather than a crash.
    private static let xlsxType: UTType =
        UTType(filenameExtension: "xlsx") ?? .data

    private func defaultSizesFilename() -> String {
        let folderName = destinationFolder?.lastPathComponent ?? "FileShuffler"
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return "\(folderName) — sizes — \(df.string(from: Date()))"
    }

    /// Static so the closure used in `result.moved.contains(where:)` doesn't
    /// capture `self` — no @MainActor isolation needed for a simple
    /// extension check.
    private static func isPDFLike(_ move: Move) -> Bool {
        let ext = move.dst.pathExtension.lowercased()
        return ext == "pdf" || ext == "ai"
    }
}

// MARK: - Clipboard suggestion model

/// Snapshot of a pasteboard string the parser accepted. We keep the raw
/// input verbatim (rather than the parsed URL) so the accept path runs
/// through the same normalisation+mount pipeline as the manual paste —
/// only one code path ever loads a base folder from a user-supplied
/// string.
fileprivate struct ClipboardSuggestion: Equatable {
    let raw: String
    let folderName: String
}

// MARK: - Sources section (multi-source list + add row)

/// Multi-source list with an inline paste field for adding more. Each
/// existing source shows as a removable row; the paste field is the
/// primary "add a source" affordance, with Browse and folder-drop as
/// secondary paths. Single-source jobs look almost identical to the v1
/// Base folder row.
fileprivate struct SourcesSection: View {
    let sources: [URL]
    @Binding var pasted: String
    let onSubmit: () -> Void
    let onBrowse: () -> Void
    let onURL: (URL) -> Void
    let onRemove: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Text(sources.count == 1 ? "Source" : "Sources")
                    .font(.caption).foregroundStyle(.secondary)
                if sources.count > 1 {
                    Text("\(sources.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                Spacer()
            }
            ForEach(sources, id: \.self) { url in
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent)
                            .font(.callout).bold()
                        Text(url.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        onRemove(url)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this source")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.06))
                )
                .padding(.leading, 32)
            }
            PathPasteField(
                placeholder: sources.isEmpty
                    ? "Paste a server link, drop a folder, or click Browse…"
                    : "Add another source — paste a server link, drop a folder, or click Browse…",
                pasted: $pasted,
                onSubmit: onSubmit,
                onBrowse: onBrowse,
                onURL: onURL
            )
            .padding(.leading, 32)
        }
    }
}

// MARK: - Destination row

/// Single-value destination input. Mirrors the source paste-row visually
/// but accepts any classification (other shares, local) since the
/// operator may consolidate output anywhere.
fileprivate struct DestinationRow: View {
    let destination: URL?
    @Binding var pasted: String
    let onSubmit: () -> Void
    let onBrowse: () -> Void
    let onURL: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Text("Destination").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            PathPasteField(
                placeholder: destination == nil
                    ? "Paste a folder link, drop a folder, or click Browse…"
                    : "Replace — paste a folder link, drop a folder, or click Browse…",
                pasted: $pasted,
                onSubmit: onSubmit,
                onBrowse: onBrowse,
                onURL: onURL
            )
            .padding(.leading, 32)
            if let destination {
                Text(destination.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 32)
            }
        }
    }
}

// MARK: - Reusable paste field with drop + browse

/// A single inline TextField that accepts pasted server links, dropped
/// folders, or a Browse-button selection. Used for both source and
/// destination inputs so the affordance is consistent.
fileprivate struct PathPasteField: View {
    let placeholder: String
    @Binding var pasted: String
    let onSubmit: () -> Void
    let onBrowse: () -> Void
    let onURL: (URL) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            TextField(placeholder, text: $pasted)
                .textFieldStyle(.plain)
                .font(.callout)
                .onSubmit(onSubmit)
            Button("Browse…", action: onBrowse)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    hovering ? Color.accentColor : Color.gray.opacity(0.25),
                    style: StrokeStyle(lineWidth: 1, dash: [4])
                )
        )
        .onDrop(of: [.fileURL], delegate: FileURLDropDelegate(hovering: $hovering, onURL: onURL))
    }
}

// MARK: - Drop target

private struct DropTarget<Trailing: View>: View {
    let title: String
    let value: String
    let systemImage: String
    @ViewBuilder var trailing: () -> Trailing
    let onURL: (URL) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    hovering ? Color.accentColor : Color.gray.opacity(0.25),
                    style: StrokeStyle(lineWidth: 1, dash: [4])
                )
        )
        .onDrop(of: [.fileURL], delegate: FileURLDropDelegate(hovering: $hovering, onURL: onURL))
    }
}

private struct FileURLDropDelegate: DropDelegate {
    @Binding var hovering: Bool
    let onURL: (URL) -> Void

    func dropEntered(info: DropInfo) { hovering = true }
    func dropExited(info: DropInfo) { hovering = false }
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func performDrop(info: DropInfo) -> Bool {
        hovering = false
        guard let provider = info.itemProviders(for: [.fileURL]).first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true)
            } else if let u = item as? URL {
                url = u
            }
            if let url {
                DispatchQueue.main.async { onURL(url) }
            }
        }
        return true
    }
}
