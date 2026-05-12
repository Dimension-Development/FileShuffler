# Installing File Shuffler

A short guide for first-time setup on a colleague's Mac. Should take about a minute.

> **Why is there an extra step?** File Shuffler is shared internally without paying Apple's £79/year Developer Programme fee, so macOS doesn't recognise the publisher. On recent macOS versions (Sequoia and later), Apple no longer offers an "Open Anyway" button for apps like this — the only way to launch it is to clear the quarantine flag that macOS adds to anything downloaded from the internet. One Terminal command does it. This is how most internal Mac tools at small companies work.

## 1. Download

Go to the **Releases** page on GitHub and download the latest `FileShuffler-vX.Y.Z.zip`:

> https://github.com/Dimension-Development/FileShuffler/releases/latest

## 2. Install

1. Double-click the `.zip` to unzip it. You'll get `FileShuffler.app`.
2. Drag `FileShuffler.app` into your **Applications** folder.

## 3. Clear the quarantine flag

Open **Terminal** (⌘+Space, type "Terminal", press Return) and paste this in, then press Return:

```
xattr -cr /Applications/FileShuffler.app
```

You won't see any output — that's fine, it means it worked. You can close Terminal now.

## 4. Launch

Double-click **FileShuffler** in your Applications folder. It should open normally. From now on it launches with a double-click like any other app.

## 5. Updates

When a new version is released:

1. Download the new ZIP from the Releases page and unzip it.
2. Drag the new `FileShuffler.app` into Applications, replacing the old one.
3. Re-run the Terminal command from step 3 — every download from GitHub gets a fresh quarantine flag that needs clearing.

## Troubleshooting

**"FileShuffler can't be opened because Apple cannot check it for malicious software" / only Cancel and Move to Trash buttons** — you skipped or need to re-run step 3. Open Terminal and run `xattr -cr /Applications/FileShuffler.app`, then try again.

**"App is damaged and can't be opened"** — usually means the ZIP got mangled in transit (some email gateways break Mac apps). Re-download from the Releases page directly, then run the Terminal command from step 3.

**An update broke launching** — re-run the Terminal command from step 3. macOS re-applies quarantine to every fresh download.

**On older macOS (Ventura / Sonoma)** — the Terminal command still works and is the simplest path. If you'd rather not use Terminal, you can instead right-click (or Control-click) the app icon in Applications, choose **Open**, then click **Open** in the dialog. That option was removed in Sequoia, so it only works on older systems.

---

Questions, problems? Ping Luke.
