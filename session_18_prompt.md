# Session 18: DMG Packaging (Ad-Hoc, Unsigned)

## Agent Orchestration
If this session's usage crosses ~85% of budget before all tasks below are complete,
stop assigning further implementation work to Sonnet subagents. Instead, orchestrate
the remaining unfinished tasks using the local `codex` CLI (already installed on this
machine) as the implementing agent — hand off clearly scoped task descriptions to it
rather than continuing to consume Sonnet context. Finish the task currently in progress
before handing off, so nothing is left half-written with no assigned agent.

## Context

Continuing "Paper Reader." The app currently builds as a Release `.app` (Session 5)
with ad-hoc signing — fine for running on this machine, but there's no distributable
package yet. This session produces a proper DMG installer for handing the app to
another Mac (mine or someone else's), using the free ad-hoc/ unsigned path — **no
Apple Developer Program enrollment, no notarization**. That means anyone installing it
will need the right-click → Open (or System Settings → Privacy & Security → Open
Anyway) workaround on first launch; that's expected and fine for this session's scope.

## Goal for this session

1. **Install tooling:** use `create-dmg` (via Homebrew — `brew install create-dmg`) to
   build the DMG rather than hand-rolling raw `hdiutil` commands.
2. **Build script:** add a script (e.g. `scripts/build_dmg.sh`) that:
   - Archives/builds the app in Release configuration (reuse whatever build
     process/scheme already exists from Session 5's packaging work — don't create a
     second, divergent build path)
   - Runs `create-dmg` against the built `.app`, producing a DMG with:
     - Volume name "Paper Reader"
     - The app icon positioned on the left, a symlink to `/Applications` on the right
       (standard drag-to-install layout)
     - A reasonable window size (doesn't need custom background art this session —
       plain is fine, that's a cosmetic follow-up if I want it later)
   - Outputs the final `.dmg` to a clearly named location (e.g. `build/PaperReader.dmg`)
   - Should be re-runnable (re-running it should cleanly overwrite the previous DMG,
     not fail because a file already exists or a previous volume is still mounted)
3. **Verify the actual install flow works:** after building, mount the DMG yourself
   (in the sandbox/CLI, e.g. via `hdiutil attach`), confirm the app icon and
   Applications symlink are both present and correctly positioned, then unmount
   cleanly. Confirm the exported `.app` inside still runs standalone (same checks as
   Session 5: correct `~/Library/Application Support/PaperReader/` usage, no
   Xcode-debug-only dependencies).
4. **Document the first-launch workaround:** add a short `INSTALL.md` (or a section in
   the existing help/Quick Tips content from Session 15) explaining, for whoever
   receives this DMG: drag to Applications, then either right-click → Open on first
   launch, or go to System Settings → Privacy & Security → "Open Anyway" if
   right-click doesn't surface the option — since a plain double-click will be blocked
   by Gatekeeper on an unsigned build.

## Explicit non-goals for this session

- No Apple Developer Program enrollment, code signing certificate, or notarization —
  ad-hoc only
- No custom DMG background artwork/branding — functional layout is enough for now
- No auto-update mechanism (Sparkle or similar) — that's a separate, later concern if
  ever needed
- No App Store submission or related packaging

## Deliverable

Running the build script produces a working `PaperReader.dmg` that, when mounted,
shows the app icon and an Applications shortcut side by side. Dragging the app into
Applications and using the right-click → Open workaround launches it successfully on a
machine that's never run it before. `INSTALL.md` (or equivalent) clearly documents that
workaround for anyone receiving the DMG. Tell me exactly where the script and the
output DMG live, and flag anything about the existing Release build process (Session 5)
that needed adjusting to make this repeatable.
