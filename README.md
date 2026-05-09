# File Shuffler

SwiftUI macOS app that reorganises a folder of files into a new structure described by a spreadsheet — preview-before-commit plan, collision-safe apply, one-click undo, optional `_xN` rename from a Quantity column, save/reopen `.shuffle` projects, and exportable audit logs. Implements **M0 + M1 + most of M2** from the [PRD](docs/PRD.md).

## What works today

- Drop or browse to a base folder.
- Drop or browse to a spreadsheet (`.xlsx`, `.csv`, `.tsv`).
- Auto-detects "File Name" / "Folder Name" columns; pickers let you override.
- Live three-section plan view:
  - **Matched** — grouped by destination folder, with ⚠ on matches that needed whitespace/case normalisation so you can spot-check them.
  - **Sheet rows with no file on disk** — typos in the sheet, or files already moved.
  - **Files not in sheet** — the orphan section. Today's job 261144 surfaces the missing Arencia A&I file here.
- **Apply moves** with confirmation, determinate progress, and per-item status. Files move under `NSFileCoordinator` so other apps with a file open (Finder, Illustrator) participate in the lock.
- **Collision dialog** when a destination already has a file of that name — Skip / Skip all / Replace / Replace all / Cancel apply. "All" choices stick for the rest of the run.
- **Undo** reverses the last apply exactly, restoring every file to its original location.
- **Quantity rename** — if your sheet has a `Quantity` (or `Qty` / `Count` / `Amount`) column, files get a `_xN` suffix on move, e.g. `foo.ai` → `foo_x30.ai`. The plan view shows the rename in blue so you can sanity-check before applying.
- **Save / Open `.shuffle` project** (Cmd-S / Cmd-O) — small JSON sidecar capturing your folder, sheet, and column choices, plus the most recent apply's audit log. Reopen tomorrow and pick up where you left off.
- **Export log…** on the apply summary — a plain-text report with operator, timestamps, base folder, every move (`src → dst`), and any skips or errors. Suitable for filing alongside the production folder.
- **Empty source folder cleanup** — after a successful apply, the result sheet surfaces source folders that are now empty (or only contain `.DS_Store`) and offers a one-click *Clean up*. Opt-in, never automatic. Removed folders go into the audit log.
- **App icon** auto-built from `assets/icon-source.png` by `scripts/bundle-app.sh`.

## How to build & run

You only need Apple's Command Line Tools (which you already have). Full Xcode is recommended for further work but not required.

```bash
cd FileShuffler
swift run
```

First build pulls down [CoreXLSX](https://github.com/CoreOffice/CoreXLSX) and `swift-testing` (a few seconds).

For a friendlier double-click launch, build the `.app` bundle:

```bash
./scripts/bundle-app.sh
open ./FileShuffler.app
```

## Tests

```bash
swift test
```

36 tests covering every engine:

- **MatchEngine** (6) — normalisation rules and the real job-261144 fixture (double-space whitespace, missing Arencia A&I orphan).
- **MoveExecutor** (7) — real-filesystem tempdir tests for apply, skip, replace, sticky replace-all, cancel, undo, and progress reporting.
- **Quantity rename** (11) — destination filename construction, column auto-detection, `mappingRows` quantity passthrough, end-to-end move-and-rename.
- **ShuffleProject I/O + AuditLog text export** (6) — JSON roundtrip with and without quantity column, future-version rejection, plain-text report formatting.
- **FolderCleanup** (6) — empty/`.DS_Store`-only detection, base-folder safety, removal, and undo-after-cleanup.

## Project layout

```
FileShuffler/
├── Package.swift
├── README.md
├── .gitignore
├── scripts/
│   └── bundle-app.sh                 # Wrap swift-build output in a .app
├── Sources/FileShuffler/
│   ├── FileShufflerApp.swift         # @main App entry
│   ├── ContentView.swift             # Window UI, drop targets, apply flow wiring
│   ├── Matching/
│   │   ├── Models.swift              # SourceFile, MappingRow, Match, MatchPlan
│   │   └── MatchEngine.swift         # Pure-functional matcher (mirrors reorganize.py)
│   ├── IO/
│   │   ├── FolderScanner.swift       # Recursive scan, hidden-file filter
│   │   └── SpreadsheetReader.swift   # XLSX (CoreXLSX) + RFC-4180 CSV/TSV
│   ├── Moving/
│   │   ├── MoveModels.swift          # Move, MoveProgress, MoveResult, UndoResult
│   │   ├── MoveExecutor.swift        # apply() + undo() with NSFileCoordinator
│   │   └── ApplyFlowViews.swift      # ApplyProgressView + ApplyResultView + PendingCollision
│   └── Project/
│       └── ShuffleProject.swift      # .shuffle JSON sidecar + AuditLog model + .txt exporter
└── Tests/FileShufflerTests/
    ├── MatchEngineTests.swift
    ├── MoveExecutorTests.swift
    ├── QuantityRenameTests.swift
    └── ProjectTests.swift
```

## What's deliberately *not* here yet

- Recents list on launch.
- Multi-window / multiple concurrent jobs.

## Won't be doing

- One-page PDF export of the audit log — the plain-text export covers the use case.
- Developer ID code signing + App Store distribution. The app is ad-hoc signed for personal use; sharing with a colleague is one right-click → Open.

## Open questions still worth validating

1. **SwiftPM-built SwiftUI on macOS 26**: `@main App` lifecycle works; window focus / dock behaviour is smoother through the bundled `.app`. If `swift run` feels janky, use `bundle-app.sh`.
2. **CoreXLSX with Swift 6.2**: pinned to 0.14.x; package resolves in Swift 5 language mode (`swift-tools-version: 5.9`). Bump to 6.0 once everything in this app is annotated for strict concurrency.
3. **Network volumes** (the SMB/AFP mount where job artwork actually lives): test the recursive scan, drop-target, and `NSFileCoordinator` move there — coordinator behaviour over SMB is the riskiest unknown.

## Migrating to a full Xcode project (later)

If Xcode is ever installed, `open Package.swift` from the project root will let you edit and run from Xcode without any conversion — the SPM package layout maps one-to-one to a normal Xcode project.
