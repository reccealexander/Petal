# Petal

Petal is a local-first macOS research-paper reader. You import PDFs into a managed library, read them in a PDFKit-based reader with highlights, comments, and rich-text notes, and organize everything into arbitrarily nested notebooks. It adds AI chat and AI-assisted note-taking (Claude or Gemini), Zotero-style citation generation (APA/MLA/Chicago/BibTeX/RIS), a "Recently Viewed" list, and per-paper reader-window size memory. Everything lives on your Mac — there is no account and no server. CloudKit sync and an iOS companion are designed but **not shipped** (see `docs/ios_cloudkit_sync_design.md`).

> **Repo name vs. app name:** The app is **Petal**, but the git repository is still named **`EasyReader`**. The remote is `github.com:reccealexander/EasyReader.git` and the local checkout folder is `EasyReader/`. Whenever you "clone the repo" below, you use the `EasyReader` URL even though what you build and run is called Petal.

## Requirements

- macOS 14 (Sonoma) or later
- A Swift 6 toolchain — Xcode 16+ or the standalone Command Line Tools (`xcode-select --install`)
- `git`

## Getting Petal onto another Mac

There are two paths. Building from source is the most reliable.

### Option A — Build from source (recommended)

```bash
git clone git@github.com:reccealexander/EasyReader.git
cd EasyReader
bash scripts/package_app.sh
```

`package_app.sh` release-builds the app (`swift build -c release`), assembles the bundle, and ad-hoc signs it. When it finishes it prints the path to the built app:

```
dist/Petal.app
```

Copy that bundle wherever you want it, e.g. into Applications:

```bash
cp -R dist/Petal.app /Applications/
```

Then open it once using the Gatekeeper workaround below.

**For developers**, the usual SPM commands work directly:

```bash
swift build      # debug build of PetalApp
swift test       # run PetalCoreTests
```

### Option B — Transfer a prebuilt app

If you've already built `dist/Petal.app` on one Mac, you can just copy that `.app` bundle to another Mac (AirDrop, USB, file share) and drop it into `/Applications`.

To hand it off as a drag-to-install disk image instead, build a DMG:

```bash
bash scripts/build_dmg.sh
```

This runs `package_app.sh` and then produces `build/Petal.dmg`.

> **Note:** `build_dmg.sh` must be run from an **interactive desktop Terminal**, not a headless or SSH session. It drives Finder via AppleScript to lay out the DMG window, which times out when there's no GUI session.

Either way, the receiving Mac opens Petal for the first time using the Gatekeeper workaround below.

## First launch (Gatekeeper)

Petal is **ad-hoc signed only** — there is no Apple Developer signing or notarization — so macOS Gatekeeper blocks a normal double-click the first time you launch it on a Mac. To get past it:

1. In **Applications** (or wherever the app is), right-click (Control-click) **Petal** and choose **Open**.
2. Click **Open** in the dialog that appears.

You only need to do this once; afterward Petal opens with a normal double-click. If **Open** stays unavailable, use **System Settings → Privacy & Security → Open Anyway**. Full steps are in [`INSTALL.md`](INSTALL.md).

## Optional setup: AI features and data

- **AI features** — Claude/Gemini chat, AI-assisted note-taking, and tag suggestions require an API key. Open Petal's **Settings** and paste a Claude and/or Gemini key; keys are stored per provider in the macOS **Keychain**, never in plaintext. Citation enrichment uses CrossRef/arXiv and needs no key. None of this is required to import, read, highlight, or annotate PDFs.
- **Where your data lives** — Petal keeps its SQLite database and a managed `Papers/` folder (your imported PDF copies) under:

  ```
  ~/Library/Application Support/Petal/
  ```

## Compatibility

macOS 14+, built with the Swift 6 toolchain. Package targets: `PetalCore` (models, database, services) and `PetalApp` (the SwiftUI/AppKit executable).
