# File Shuffler — Product Requirements Document

**Status:** Draft v0.1
**Author:** Luke Atkins (with Claude)
**Date:** 2026-05-09
**Platform:** macOS 14+ (native, Swift / SwiftUI)

---

## 1. One-liner

A native macOS app that takes a folder of print/laser job artwork and a mapping spreadsheet, and reorganises the files into the destination folder structure described by the sheet — safely, visibly, and reversibly.

## 2. Problem & opportunity

Print & Laser operatives regularly receive jobs as a folder of artwork files (Adobe Illustrator `.ai`, occasionally PDFs) sorted by **brand** or **job number**. Production needs them re-sorted by **material / substrate** (e.g. *1250mic Libra GCDB*, *200gsm Metro Vibe Satin*, *100mic Orajet 3164 SAV*, *Dtec Tearproof*). The destination grouping is supplied as a spreadsheet listing every file alongside its target folder.

Today this is done manually in Finder: create the new folders, click-and-drag each file, repeat ~40+ times per job, then delete the empty originals. It is:

- **Slow** — five to fifteen minutes per job, and several jobs land per day.
- **Error-prone** — small whitespace/spelling differences between filename and sheet, files dropped into the wrong substrate folder, easy to miss one.
- **Hard to audit** — once moves are done there is no log of what went where.

A purpose-built tool removes the manual step and the mistakes, and gives the operator a confident "preview before commit" workflow.

> A Python CLI script and a Claude skill (`organize-files-from-list`) already exist and prove the core matching logic. This PRD scopes a native Mac app that a non-technical operator can use without opening a terminal.

## 3. Target user

Primary: **Luke** and other Print & Laser operatives at the same company.

Secondary: anyone in a small print/production shop with the same brand-to-substrate reorganisation workflow.

Characteristics:

- Comfortable with macOS Finder, Excel/Numbers, Adobe Illustrator.
- Not a developer — should never need to open a terminal.
- Work locally; files live on the Desktop or a shared network volume.
- Care a lot about not losing or misfiling source artwork.

## 4. Goals (v1)

1. Reorganise a folder of files according to a spreadsheet mapping in **under 30 seconds of user time per job**, end to end.
2. **Zero silent mistakes:** every unmatched file (in either direction) is surfaced before any move happens.
3. **Reversible:** any apply step can be undone in one click for at least the current session.
4. Run **fully offline** — no cloud, no telemetry, no account.
5. Native macOS app installable by drag-to-Applications. Ad-hoc signed; no Developer ID / App Store distribution (deliberately out of scope — see §5).

## 5. Non-goals (v1)

- Editing the spreadsheet in-app (open it in Numbers/Excel).
- Editing artwork (`.ai` previews are nice-to-have, not edit).
- Multi-user collaboration or shared cloud state.
- Windows / iPad / web.
- Generating the mapping spreadsheet automatically from filenames (possible v2).
- Copying instead of moving (v2 if requested).
- **PDF export of the audit log** — the plain-text export covers the use case; not worth the complexity.
- **Developer ID code signing, notarisation, App Store distribution.** Requires the paid Apple Developer Program. Ad-hoc signing is sufficient for personal use; colleagues open via right-click → Open.

## 6. Core user stories

1. *As an operative,* I drop a job folder and its mapping spreadsheet onto the app and see a preview of every file, where it will go, and any problems — before anything moves.
2. *As an operative,* when the sheet missed a file (e.g. a brand is omitted from one row), the app shows me the orphan, lets me pick a destination, and remembers it for "Apply".
3. *As an operative,* after applying I can undo and put everything back exactly as it was.
4. *As an operative,* I can save a small `.shuffle` project so I can re-open today's job tomorrow if I get interrupted.
5. *As an operative,* when the job is done I can export a plain-text log of what moved where, for the production folder.

## 7. Detailed functional requirements

### 7.1 Project input

- **Folder picker:** standard macOS open dialog, or drag-drop a folder onto the app window / Dock icon. Recursive scan; ignore `.DS_Store` and dotfiles.
- **Spreadsheet picker:** accept `.xlsx`, `.xls`, `.csv`, `.tsv`. Drag-drop also supported.
- The spreadsheet may live inside the job folder (it usually does); the app must not include the spreadsheet itself in the file list to be moved.

### 7.2 Column detection

- After loading the sheet, the app shows the first row and lets the user pick which column is **File Name** and which is **Folder Name**.
- Smart default: auto-select columns whose headers match (case-insensitive) `file`, `filename`, `name`, `artwork` (file column) and `folder`, `destination`, `material`, `substrate` (folder column).
- The user can change either selection without restarting.

### 7.3 Match preview ("Plan" view)

The main screen, shown after inputs are loaded. Three sections:

1. **Matched (will move)** — list grouped by destination folder, with a count badge per group. Each row shows:
   - Source filename
   - Source subfolder (relative to the base)
   - Destination folder name
   - Status icon (✓ matched cleanly, ⚠ matched after whitespace/case normalisation)
2. **Sheet rows with no file on disk** — likely typos in the sheet, or files already moved. Each row offers: *Edit name to fix*, *Ignore this row*, or *Pick a file manually*.
3. **Files not in sheet** — orphans. Each row offers: *Choose destination folder…* (with autocomplete from the destinations already in use), *Use the same folder as a similar file* (e.g. all "A&I graphic" files), or *Leave in place*.

The app must not start moving anything until the user clicks **Apply moves**.

### 7.4 Matching rules (must match the existing script)

- Compare on filename without extension.
- Lowercase before compare.
- Collapse runs of whitespace to a single space.
- Trim leading/trailing whitespace.
- Tag the match as "normalised" (⚠) if any of the above changed the input, so the operator can sanity-check.

### 7.5 Apply moves

- Single button, **Apply moves**, with a confirmation that names the base folder and the number of files about to move.
- Show a determinate progress bar.
- Use `FileManager.moveItem(at:to:)` with file coordination.
- On collision (destination filename already exists): pause and ask *Skip / Replace / Replace all / Cancel*.
- After completion, present a summary: *N files moved, X skipped, Y errors* and offer **Undo**.

### 7.6 Cleanup

- After a successful apply, offer to remove now-empty source subfolders.
- Default off; user must opt in.
- Match by prefix (e.g. "261144 - ") configurable in the cleanup dialog, defaulting to the longest common prefix among original source subfolders.
- Always remove `.DS_Store` inside an otherwise-empty folder before deleting that folder.

### 7.7 Undo

- Reverses the most recent apply for the current session, by reading an in-memory journal of `(src, dst)` pairs.
- Restores any deleted source subfolders.
- Available until the user clicks "New job" or quits.
- Quitting the app warns if the last apply has not been undone or confirmed.

### 7.8 Audit log / export

- On every apply, append entries to a per-job log (kept inside `.shuffle` project state, see 7.9).
- Provide **Export log…** producing a plain-text `.txt` report with date, operator, base folder, sheet, every move (`src → dst`), skips, errors, and any folders cleaned up. Suitable for filing alongside the job.

### 7.9 Project file (`.shuffle`)

- Lightweight JSON sidecar storing: base folder bookmark, sheet bookmark, chosen columns, manual destination overrides, applied/undone state, log entries.
- Saved next to the job folder by default, but the user can save anywhere.
- Bookmarks must be **security-scoped** so the app can re-resolve them after sandboxing.

### 7.10 Recents

- The app remembers the last ~10 job folders and offers them on launch.

## 8. UX flow

```
 Launch
   │
   ▼
 Welcome screen ──── pick recent job ┐
   │                                 │
   │ drop folder + sheet             │
   ▼                                 ▼
 Plan view (Matched / Sheet-only / Disk-only)
   │            ▲
   │ resolve    │ user fixes orphans, ignores rows, picks destinations
   ▼            │
 Apply moves ───┘
   │
   ▼
 Summary  ── Undo ──► Plan view
   │
   ▼
 Optional: cleanup empty folders, export log, save .shuffle
```

## 9. Visual layout (text sketch)

```
┌────────────────────────────────────────────────────────────────┐
│  File Shuffler                                       [+ New] │
├────────────────────────────────────────────────────────────────┤
│  Base folder:  /Desktop/.../261144                       [...] │
│  Spreadsheet:  261144.xlsx       File col ▾   Folder col ▾    │
├────────────────────────────────────────────────────────────────┤
│  ▼ Matched — 44                                                │
│    ▸ 1250mic Libra GCDB ……………………………………………………… 11           │
│    ▸ 200gsm Metro Vibe Satin Poster Paper ……………………… 11        │
│    ▸ 100mic Orajet 3164 Matte White SAV ………………………… 11         │
│    ▸ 122791 Dtec Tearproof Matt Synthetic Paper ………… 11        │
│  ▼ Sheet rows with no file (0)                                 │
│  ▼ Files not in sheet (1)                                      │
│    • 261144 - Arencia - A&I graphic 150mm x160mm.ai            │
│        Destination: [ 200gsm Metro Vibe ▾ ] [Apply pattern]    │
├────────────────────────────────────────────────────────────────┤
│                                  [ Apply moves ]   [ Cancel ]  │
└────────────────────────────────────────────────────────────────┘
```

## 10. Non-functional requirements

| Area | Requirement |
|---|---|
| Performance | Plan view ready within 2 s for ≤ 500 files. |
| Reliability | Never move a file before user clicks Apply. Use file coordination to avoid clashes with Finder/Illustrator. |
| Safety | All moves journaled; Undo restores original locations exactly. |
| Privacy | No network calls. No analytics. |
| Accessibility | Full VoiceOver labels, keyboard navigation, Dynamic Type for the file list. |
| Localisation | English (en-GB) v1. Strings externalised so en-US / additional locales are trivial later. |
| Distribution | Ad-hoc signed `.app`. Shared informally (drag-to-Applications, right-click → Open on first launch). No Developer ID, no notarisation, no App Store. |
| Sandboxing | Off. App runs unsandboxed; security-scoped bookmarks not required. |

## 11. Technical stack

- **Language / UI:** Swift 5.9+, SwiftUI for views, AppKit only where needed (drag-drop, NSOpenPanel customisations).
- **Min target:** macOS 14 (Sonoma). Justified because we want SwiftUI Table refinements and `Observation`.
- **XLSX parsing:** [CoreXLSX](https://github.com/CoreOffice/CoreXLSX) (read-only is fine; MIT-licensed).
- **CSV/TSV:** small in-house parser (or `swift-csv`).
- **File access:** `FileManager`, `NSFileCoordinator`. No security-scoped bookmarks (app is unsandboxed).
- **Persistence:** Codable JSON for `.shuffle`. No Core Data / SwiftData v1.
- **Logging:** `os.Logger` for diagnostics; user-visible audit log exports to plain `.txt`.
- **Testing:** swift-testing (`@Test` / `#expect`) for the matching, move, project, and cleanup engines — pure tempdir tests, no UI.

## 12. Risks & open questions

1. **Network volumes** — files often live on a shared SMB mount. Need to test `NSFileCoordinator` move behaviour there. *Action:* validate on a real shared volume.
2. **`.ai` previews** — Quick Look generates them, but they can be slow on big files. Out of scope for v1 unless cheap; otherwise defer.
3. **Multi-row matches** — what if two files normalise to the same key? Decision: surface a conflict and require manual disambiguation, never auto-pick.
4. **Operator naming differences** — should we offer fuzzy matching (Levenshtein) for orphans? Decision: not in v1; show clearly and let the user fix manually. Reconsider if data shows it would help.
5. **Multiple concurrent jobs** — single-window v1; tabs / multi-window v2 if requested.

## 13. Success metrics

- Time per job from drop to "Apply complete": **< 30 s** for an experienced user (vs ~5–15 min manually).
- **Zero** misfiled artworks reported in the first month of use.
- **100%** of orphaned files are surfaced (validate via real use on at least 10 jobs).
- App launches and is usable within 1 s on the target Mac.

## 14. Milestones

| Milestone | Scope | ETA |
|---|---|---|
| **M0 — Spike** | Plain SwiftUI window. Drop folder + .xlsx, list files, list rows, do match. No moves. | shipped |
| **M1 — Plan & apply** | Three-section plan view, apply with collision handling, Undo. | shipped |
| **M2 — Polish** | Empty-folder cleanup, audit log + plain-text export, `.shuffle` project save/load, app icon, ad-hoc signing. Recents pending. | mostly shipped |

## 15. Maybe later (parked for v2+)

These could be revisited if real use surfaces a need:

- Auto-generating the mapping sheet from filename heuristics.
- Copy mode (instead of move) and templated destinations.
- A "rules" engine: e.g. "anything ending in *Shelf liner* → Libra GCDB" without a sheet.
- Direct integration with Adobe Illustrator (open / preview).
- Cloud sync of project files.
- Multi-window / multi-job.
- Windows port.

Items explicitly **not on the roadmap** (PDF audit-log export, Developer ID signing / notarisation / App Store distribution) are in §5 (non-goals).

## 16. Appendix — reference data

Real example used to validate the matching engine (today's job 261144):

- 11 brand source folders × 4 file types = 44 `.ai` files.
- 4 destination material folders.
- One file (`261144 - Arencia - A&I graphic 150mm x160mm.ai`) was missing from the sheet — exactly the kind of orphan the **Files not in sheet** section must surface.
- Filename whitespace inconsistencies (`261144 -  By Ellie` with two spaces vs `261144 - By Ellie` with one) must match cleanly.
