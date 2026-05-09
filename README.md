# File Shuffler — M1

SwiftUI macOS app that reorganises a folder of files into a new structure described by a spreadsheet — preview-before-commit plan, collision-safe apply, one-click undo. Implements the **M0 (Spike)** + **M1 (Plan & apply)** scopes from the [PRD](../PRD.md).

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

13 tests covering both engines:

- **MatchEngine** (6) — normalisation rules and the real job-261144 fixture (double-space whitespace, missing Arencia A&I orphan).
- **MoveExecutor** (7) — real-filesystem tempdir tests for apply, skip, replace, sticky replace-all, cancel, undo, and progress reporting.

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
│   └── Moving/
│       ├── MoveModels.swift          # Move, MoveProgress, MoveResult, UndoResult
│       ├── MoveExecutor.swift        # apply() + undo() with NSFileCoordinator
│       └── ApplyFlowViews.swift      # ApplyProgressView + ApplyResultView + PendingCollision
└── Tests/FileShufflerTests/
    ├── MatchEngineTests.swift
    └── MoveExecutorTests.swift
```

## What's deliberately *not* here yet (M2+)

- Empty-source-folder cleanup after a successful apply.
- `.shuffle` project save/load with security-scoped bookmarks.
- Audit log + one-page PDF export.
- Recents list on launch.
- App Sandbox + entitlements + signing/notarisation.
- Multi-window / multiple concurrent jobs.

## Open questions still worth validating

1. **SwiftPM-built SwiftUI on macOS 26**: `@main App` lifecycle works; window focus / dock behaviour is smoother through the bundled `.app`. If `swift run` feels janky, use `bundle-app.sh`.
2. **CoreXLSX with Swift 6.2**: pinned to 0.14.x; package resolves in Swift 5 language mode (`swift-tools-version: 5.9`). Bump to 6.0 once everything in this app is annotated for strict concurrency.
3. **Network volumes** (the SMB/AFP mount where job artwork actually lives): test the recursive scan, drop-target, and `NSFileCoordinator` move there — coordinator behaviour over SMB is the riskiest unknown.

## Migrating to a full Xcode project (later)

When Xcode is installed, `open Package.swift` from the project root will let you edit and run from Xcode immediately. For App Store-style distribution (signing, sandbox, entitlements) you'll want a `.xcodeproj`; the cleanest path is `File > New > Project > macOS App` and copy the source files in — the SPM package is intentionally laid out so the move is one-to-one.
