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
    @State private var baseFolder: URL?
    @State private var sheetURL: URL?
    @State private var sheetTable: SpreadsheetTable?
    @State private var fileColumn: String = ""
    @State private var folderColumn: String = ""
    @State private var files: [SourceFile] = []
    @State private var plan: MatchPlan?
    @State private var error: String?

    // M1 — apply / undo flow state
    @State private var applyPhase: ApplyPhase = .idle
    @State private var applyProgress: MoveProgress?
    @State private var applyResult: MoveResult?
    @State private var undoResult: UndoResult?
    @State private var pendingCollision: PendingCollision?
    @State private var confirmingApply = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
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
        .frame(minWidth: 760, minHeight: 560)
        .alert(
            "Move \(plan?.matched.count ?? 0) files?",
            isPresented: $confirmingApply,
            presenting: plan
        ) { _ in
            Button("Move", action: startApply)
            Button("Cancel", role: .cancel, action: {})
        } message: { _ in
            Text("Files will move from their current locations into the destination folders shown in the plan. Files not listed in the sheet are left in place.")
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

    private var footer: some View {
        HStack {
            Spacer()
            Button("Apply moves") {
                confirmingApply = true
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(plan?.matched.isEmpty ?? true)
        }
    }

    // MARK: - Apply sheet content

    @ViewBuilder
    private var applySheetContent: some View {
        switch applyPhase {
        case .applying:
            ApplyProgressView(
                title: "Applying moves…",
                progress: applyProgress,
                onCancel: nil    // collision dialog already offers Cancel apply
            )
        case .undoing:
            ApplyProgressView(
                title: "Undoing…",
                progress: applyProgress,
                onCancel: nil
            )
        case .completed, .undone:
            if let result = applyResult {
                ApplyResultView(
                    result: result,
                    undoResult: undoResult,
                    onUndo: startUndo,
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
            Text("M0 spike — preview only, no moves yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if plan != nil {
                Button("New job", action: reset)
            }
        }
    }

    // MARK: - Inputs

    private var inputs: some View {
        VStack(alignment: .leading, spacing: 10) {
            DropTarget(
                title: "Base folder",
                value: baseFolder?.path ?? "Drop a folder here, or click Browse…",
                systemImage: "folder",
                trailing: { Button("Browse…", action: pickFolder) },
                onURL: setBase
            )
            DropTarget(
                title: "Spreadsheet",
                value: sheetURL?.lastPathComponent ?? "Drop an .xlsx, .csv, or .tsv here",
                systemImage: "tablecells",
                trailing: { Button("Browse…", action: pickSheet) },
                onURL: setSheet
            )
            if let table = sheetTable {
                HStack(spacing: 16) {
                    columnPicker(label: "File column", selection: $fileColumn, options: table.headers)
                    columnPicker(label: "Folder column", selection: $folderColumn, options: table.headers)
                    Spacer()
                }
                .onChange(of: fileColumn) { rebuildPlan() }
                .onChange(of: folderColumn) { rebuildPlan() }
            }
        }
    }

    private func columnPicker(label: String, selection: Binding<String>, options: [String]) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 280)
        }
    }

    // MARK: - Plan view

    @ViewBuilder
    private var content: some View {
        if let plan {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    matchedSection(plan)
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
                Text("Drop a job folder and its spreadsheet to see the plan.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            Spacer()
        }
    }

    private func matchedSection(_ plan: MatchPlan) -> some View {
        let grouped = Dictionary(grouping: plan.matched, by: { $0.destination })
        return planSection(title: "Matched — will move", count: plan.matched.count, tint: .green) {
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
                                    Text(m.source.relativePath)
                                        .font(.callout.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
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
                    Text(f.relativePath).font(.callout.monospaced())
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
        baseFolder = nil
        sheetURL = nil
        sheetTable = nil
        fileColumn = ""
        folderColumn = ""
        files = []
        plan = nil
        error = nil
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { setBase(url) }
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

    private func setBase(_ url: URL) {
        baseFolder = url
        rescan()
    }

    private func setSheet(_ url: URL) {
        sheetURL = url
        do {
            let table = try SpreadsheetReader.read(url)
            sheetTable = table
            let detected = table.detectColumns()
            fileColumn = detected.file ?? table.headers.first ?? ""
            folderColumn = detected.folder ?? (table.headers.dropFirst().first ?? "")
            error = nil
            rescan()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func rescan() {
        guard let baseFolder else { return }
        do {
            let exclude: Set<URL> = sheetURL.map { [$0.standardizedFileURL.resolvingSymlinksInPath()] } ?? []
            files = try FolderScanner.scan(base: baseFolder, excluding: exclude)
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
            let rows = try table.mappingRows(fileColumn: fileColumn, folderColumn: folderColumn)
            plan = MatchEngine.plan(files: files, rows: rows)
            error = nil
        } catch {
            plan = nil
            self.error = error.localizedDescription
        }
    }

    // MARK: - Apply / Undo

    private func startApply() {
        guard let baseFolder, let plan, !plan.matched.isEmpty else { return }
        let matches = plan.matched
        applyPhase = .applying
        applyProgress = MoveProgress(total: matches.count, done: 0, current: "")
        applyResult = nil
        undoResult = nil

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
                baseFolder: baseFolder,
                callbacks: callbacks
            )
            await MainActor.run {
                applyResult = result
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
            let undo = await MoveExecutor.undo(moves)
            await MainActor.run {
                undoResult = undo
                applyPhase = .undone
            }
        }
    }

    /// Close the apply/undo sheet and refresh the plan against the new state
    /// of the disk — after a successful apply, the source folders are empty;
    /// after an undo they're back. Either way the plan should be re-derived.
    private func finishApplyFlow() {
        applyPhase = .idle
        applyProgress = nil
        applyResult = nil
        undoResult = nil
        rescan()
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
