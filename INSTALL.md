# Installing File Shuffler

A short guide for first-time setup on a colleague's Mac. Should take about a minute.

> **Why is there a security warning the first time?** File Shuffler is shared internally without paying Apple's £79/year Developer Programme fee, so macOS doesn't recognise the publisher. The app is the same as the one you're being sent, but you'll need to tell macOS once that you trust it. After that it just runs normally. This is how most internal Mac tools at small companies work.

## 1. Download

Go to the **Releases** page on GitHub and download the latest `FileShuffler-vX.Y.Z.zip`:

> https://github.com/Dimension-Development/FileShuffler/releases/latest

## 2. Install

1. Double-click the `.zip` to unzip it. You'll get `FileShuffler.app`.
2. Drag `FileShuffler.app` into your **Applications** folder.

## 3. First launch (the one-time security dance)

Try to open File Shuffler. **macOS will block it the first time** with a message like:

> *"File Shuffler can't be opened because Apple cannot check it for malicious software."*

That's expected. Here's how to allow it:

1. Click **Done** to dismiss the warning.
2. Open **System Settings** (Apple menu → System Settings).
3. In the sidebar, click **Privacy & Security**.
4. Scroll down to the **Security** section.
5. You'll see a message: *"File Shuffler was blocked to protect your Mac."* Click **Open Anyway** next to it.
6. Confirm with your password / Touch ID.
7. macOS will now ask once more if you really want to open it — click **Open**.

That's it. From now on, File Shuffler launches normally with a double-click.

## 4. Updates

When a new version is released, download the new ZIP from the Releases page, unzip it, and drag the new `FileShuffler.app` into Applications, replacing the old one. macOS will keep your "trusted" status — no need to repeat the security dance.

## Troubleshooting

**"App is damaged and can't be opened"** — usually means the ZIP got mangled in transit (some email gateways break Mac apps). Re-download from the Releases page directly. If that doesn't help, open Terminal and run:

```
xattr -cr /Applications/FileShuffler.app
```

then try opening again.

**The security dance doesn't seem to have worked** — sometimes macOS is fussy. Try right-clicking (or Control-clicking) the app icon in Applications, choose **Open**, then click **Open** in the dialog that appears. That's an alternative path to the same outcome.

**An update broke launching** — re-run the security dance from step 3. macOS occasionally re-quarantines apps after big system updates.

---

Questions, problems? Ping Luke.
