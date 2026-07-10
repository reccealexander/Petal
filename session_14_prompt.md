# Session 14: Appearance Transparency, Focus Mode, Global Search

## Agent Orchestration
If this session's usage crosses ~85% of budget before all tasks below are complete,
stop assigning further implementation work to Sonnet subagents. Instead, orchestrate
the remaining unfinished tasks using the local `codex` CLI (already installed on this
machine) as the implementing agent — hand off clearly scoped task descriptions to it
rather than continuing to consume Sonnet context. Finish the task currently in progress
before handing off, so nothing is left half-written with no assigned agent.

## Context

Continuing "Paper Reader." Three features, each touching window chrome/appearance in
a different way.

## 1. Transparency slider (Settings → Appearance)

- Slider range 1–100 (percent), affecting the **main library window** only.
- At **1%**: window chrome (toolbar background, sidebar background, window
  background material) is essentially fully transparent — but paper card content
  (thumbnail image, title, page count, tags) must remain fully visible/legible. This
  means a two-layer approach: a "chrome" layer whose alpha ties directly to the
  slider, and a "content" layer (the cards themselves) that stays opaque regardless of
  slider position.
- At **100%**: looks exactly as it does today (fully opaque).
- Interpolate chrome alpha linearly between those two endpoints unless that reads
  poorly in practice — flag whatever curve you actually used.
- Implement via `NSVisualEffectView` material/alpha adjustments on the chrome layer,
  keeping card content in a separate non-affected layer.

## 2. Focus mode

- A toggle button in the reader window's title bar. While active:
  - Everything except the PDF page content itself becomes fully transparent — toolbar,
    sidebar, thumbnail strip, notes affordances, window chrome, and any gray
    background space around the page.
  - All other windows on the desktop are hidden — **both Paper Reader's own other
    windows and other applications' windows.** Implement this via
    `NSRunningApplication.hide()` on every other running application (this hides an
    app's entire window set without requiring Accessibility permissions), plus
    ordering/hiding Paper Reader's own non-focused windows directly. Do **not**
    attempt per-window manipulation via the Accessibility API (`AXUIElement`) — that
    requires the user to grant Accessibility permission in System Settings and is far
    more fragile; hiding whole applications is the simpler, permission-free approach
    and is what to use here.
  - Track which applications were hidden so they can be restored (unhidden) on exit,
    rather than leaving everything hidden after the user exits focus mode.
- Exit via **Escape key**, or via a **"Exit Focus Mode" item under a "View" menu** in
  the macOS menu bar (add a View menu if one doesn't exist yet).

## 3. Shift+\` global search

- `Shift+\`` opens a floating, centered search overlay (Spotlight-style), searching
  paper titles and notebook names — reuse the FTS-backed search plumbing from Session
  5 rather than building a second search path.
- Selecting a result opens/focuses that paper or notebook.
- **Scope check:** a true system-wide hotkey (works even when Paper Reader isn't the
  focused app) needs either Accessibility permission + a global event monitor, or the
  Carbon hotkey API — meaningfully more complex and requires the user to grant a
  permission. An app-local shortcut (only fires while Paper Reader is focused) is far
  simpler and needs nothing special. Implement the **app-local** version for this
  session, and only attempt the global version if it turns out to be trivial — flag
  clearly which you built.

## Non-goals

- No persisting focus-mode or hidden-app state across app relaunch
- No customizable transparency curve/settings beyond the single slider
- No search result previews beyond title/name + type (paper vs. notebook)

## Deliverable

App builds and runs. The transparency slider fades chrome while keeping card content
legible at the low end, and matches current appearance at 100%. Focus mode strips the
reader down to just the PDF and hides other windows/apps, restorable via Escape or the
View menu. Shift+\` opens a search overlay that finds papers and notebooks by title/
name and jumps to the selection. Flag your alpha-interpolation curve for the
transparency slider and whether the search shortcut ended up app-local or global.
