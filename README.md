# File Shuffler

SwiftUI macOS app that reorganises a folder of files into a new structure described by a spreadsheet — preview-before-commit plan, collision-safe **copy** into the destination (originals stay where they are), one-click removal of the copies, optional `_xN` rename from a Quantity column, save/reopen `.shuffle` projects, and exportable audit logs. Implements **M0 + M1 + most of M2** from the [PRD](docs/PRD.md).

**Installing on a colleague's Mac?** See [INSTALL.md](INSTALL.md) — short guide aimed at end-users.

## What works today

- Drop or browse to a base folder.
- Drop or browse to a spreadsheet (`.xlsx`, `.csv`, `.tsv`).
- **V1 job-sheet support** — multi-worksheet workbooks get a worksheet picker (the sheet with recognisable job columns is auto-selected, e.g. "Print & Laser"); the header row is found beneath banner/meta rows by content; sparse XLSX rows are placed by cell reference so empty cells never shift columns; and workbooks whose relationship list contains types CoreXLSX can't decode (modern Excel's `sheetMetadata`) parse via a tolerant fallback reader.
- **Source auto-populated from the job sheet** — a server link in the banner rows (the "ARTWORK AT:" row) is parsed, the share mounted if needed, and the folder added as a source the moment the workbook loads. Dropping one file sets up the whole job.
- Auto-detects the file / folder / quantity columns, plus "Artwork name Front/Back", "Material", and "Colour Spec"; pickers let you override.
- **Nested destinations** — an optional Subfolder column (e.g. Colour Spec) routes copies into `<Folder>/<Subfolder>`. Cell values are sanitised (`/` and `:` become `-`, so a colour spec like "4/0 - Print to Face" is one folder, not two).
- **Back artwork column** — rows with a second artwork file emit an extra copy into the same folder; per-page duplicate rows (same file, same destination) collapse into one, dropping the quantity if the pages disagree.
- Sheet cells may include the artwork extension ("foo.pdf" matches the file `foo.pdf`); a whitelist of artwork extensions keeps dots inside names (e.g. "artwork v1.2") intact.
- Live three-section plan view:
  - **Matched** — grouped by destination folder, with ⚠ on matches that needed whitespace/case normalisation so you can spot-check them.
  - **Sheet rows with no file on disk** — typos in the sheet, or files already moved.
  - **Files not in sheet** — the orphan section. Today's job 261144 surfaces the missing Arencia A&I file here.
- **Copy files** with confirmation, determinate progress, and per-item status. Files are **copied** — the originals never leave their source folders. Transfers run under `NSFileCoordinator` so other apps with a file open (Finder, Illustrator) participate in the lock. (The executor still implements move mode, kept tested, should a per-job toggle ever be wanted.)
- **Collision dialog** when a destination already has a file of that name — Skip / Skip all / Replace / Replace all / Cancel apply. "All" choices stick for the rest of the run.
- **Remove copies** (undo) — deletes every copy the last apply created; the originals were never touched.
- **Quantity rename** — if your sheet has a `Quantity` (or `Qty` / `Count` / `Amount`) column, the copies get a `_xN` suffix, e.g. `foo.ai` → `foo_x30.ai`. The plan view shows the rename in blue so you can sanity-check before applying.
- **Idempotent re-runs** — the matcher uses a two-pass approach (exact first, then with `_xN` stripped) so a folder of already-renamed files can be re-processed cleanly. Files matched via the strip pass are flagged ⚠ and have their existing `_xN` *replaced* by the new quantity rather than stacked. Files with a *legitimate* `_xN` in the original name are matched exactly first and left untouched.
- **Save / Open `.shuffle` project** (Cmd-S / Cmd-O) — small JSON sidecar capturing your folder, sheet, and column choices, plus the most recent apply's audit log. Reopen tomorrow and pick up where you left off.
- **Export log…** on the apply summary — a plain-text report with operator, timestamps, base folder, every copy (`src → dst`), and any skips or errors. Suitable for filing alongside the production folder. Logs record whether the job copied or moved; old logs without that field read as moves.
- **Empty source folder cleanup** — move-mode only, so dormant while the app copies: copying never empties a source folder. The code and tests remain for a future move toggle.
- **Export sizes…** on the apply summary — produces a CSV listing every PDF/AI page in the destination folders with:
  - Width × height in millimetres, using **TrimBox where defined, falling back to MediaBox** (matching print-prepress convention); fallback rows are flagged in a Notes column.
  - **Spot colours** declared on the page or in any placed Form XObject (cutter templates, brand-logo PDFs). Reported verbatim from the PDF, deduped, alphabetised, semicolon-separated. CMYK-only pages get an empty cell. Process colorants and `/All` / `/None` special separations are filtered out.
  - One row per page for multi-page PDFs. Files PDFKit can't read get a "Couldn't read" row, never silently skipped.
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

120 tests covering every engine:

- **MatchEngine** (8) — normalisation rules and the real job-261144 fixture (double-space whitespace, missing Arencia A&I orphan).
- **MoveExecutor** (10) — real-filesystem tempdir tests for apply, skip, replace, sticky replace-all, cancel, undo, and progress reporting in move mode, plus copy mode: originals left in place, undo deletes the copies, collision Replace overwrites without touching the source.
- **Quantity rename** (11) — destination filename construction, column auto-detection, `mappingRows` quantity passthrough, end-to-end transfer-and-rename.
- **PathNormaliser** (25) — pasted works-order links in every observed shape (UNC, smb/afp URLs, `/Volumes/`, quotes, percent-encoding) and the source vs destination acceptance policies.
- **SpreadsheetReader — V1 job sheet** (16) — against a dummy-data fixture mirroring the real job-sheet structure: worksheet listing/auto-pick, header row beneath banner rows, sparse-cell column alignment, front/back/material/colour-spec/qty detection, Material/Colour-Spec nesting with sanitised slashes, per-page dedup, quantity-disagreement handling, the unknown-relationship fallback reader, sheet-cell extension stripping, and banner artwork-link extraction.
- **ShuffleProject I/O + AuditLog text export** (10) — JSON roundtrip with and without quantity column, future-version rejection, plain-text report formatting including copy vs move (and legacy) wording.
- **FolderCleanup** (6) — empty/`.DS_Store`-only detection, base-folder safety, removal, and undo-after-cleanup.
- **PDFSizeExtractor + SizesReport CSV** (13) — fixture PDFs generated at runtime via Core Graphics (single-page A4, multi-page, MediaBox-only, MediaBox+TrimBox), missing/non-PDF graceful failure, RFC 4180 quoting for filenames with commas/quotes, fallback note in Notes column.
- **SpotColourExtractor + CSV integration** (9) — hand-written minimal PDF fixtures with declared `Separation` colour spaces, single/multiple/duplicate spots, process-colorant filtering, `/All` filtering, page-level + Form-XObject merging, semicolon-separated CSV output.
- **Idempotent matching + rename** (12) — strip helper edge cases (case insensitivity, mid-string `_xN` preserved, refuses empty); two-pass priority (exact wins over stripped when both could match); destination filename behaviour for Pass-1 vs Pass-2 matches across all four scenarios in the README behaviour table.

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
│   │   ├── SpreadsheetReader.swift   # XLSX (CoreXLSX + fallback) + RFC-4180 CSV/TSV; header detection, nesting
│   │   ├── PathNormaliser.swift      # Pasted works-order links → /Volumes/ URLs + policy
│   │   └── NetFSMounter.swift        # Auto-mount the DimensionHub share via NetFS
│   ├── Moving/
│   │   ├── MoveModels.swift          # TransferMode, Move, MoveProgress, MoveResult, UndoResult
│   │   ├── MoveExecutor.swift        # apply() + undo() (copy or move) with NSFileCoordinator
│   │   ├── FolderCleanup.swift       # Empty-source-folder detection + removal (move mode)
│   │   └── ApplyFlowViews.swift      # ApplyProgressView + ApplyResultView + PendingCollision
│   ├── Project/
│   │   └── ShuffleProject.swift      # .shuffle JSON sidecar + AuditLog model + .txt exporter
│   └── Sizing/
│       ├── PageSize.swift              # PageSize, FilePageSizes models (incl. spotColours)
│       ├── PDFSizeExtractor.swift      # PDFKit + CG dictionary check; mm output, TrimBox→MediaBox fallback
│       ├── SpotColourExtractor.swift   # CGPDF dictionary walk for Separation/DeviceN, with XObject recursion
│       └── SizesReport.swift           # CSV builder with RFC 4180 quoting
└── Tests/FileShufflerTests/
    ├── Fixtures/                     # Dummy-data V1 job-sheet workbooks
    ├── MatchEngineTests.swift
    ├── MoveExecutorTests.swift
    ├── QuantityRenameTests.swift
    ├── SpreadsheetReaderTests.swift
    ├── PathNormaliserTests.swift
    ├── ProjectTests.swift
    ├── FolderCleanupTests.swift
    ├── PDFSizingTests.swift
    ├── SpotColourTests.swift
    └── IdempotentRenameTests.swift
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
