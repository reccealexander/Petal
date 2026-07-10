# Session 13: Universal Window Joining + Page Earmarks

## Agent Orchestration
If this session's usage crosses ~85% of budget before all tasks below are complete,
stop assigning further implementation work to Sonnet subagents. Instead, orchestrate
the remaining unfinished tasks using the local `codex` CLI (already installed on this
machine) as the implementing agent — hand off clearly scoped task descriptions to it
rather than continuing to consume Sonnet context. Finish the task currently in progress
before handing off, so nothing is left half-written with no assigned agent.

## Context

Continuing "Paper Reader." Session 9 built window snapping specifically for two PDF
reader windows. This session generalizes that into a universal system that works for
any pair of window types, and separately adds page earmarking to the thumbnail sidebar.

## 1. Universal window joining

Generalize Session 9's snap logic so **any two** of the following can combine into a
single split-view window when dragged adjacent: a reader window (PDF), a notes window,
and the main library window.

- Refactor whatever Session 9 built into a reusable, content-agnostic
  `WindowSnapController` (or similar) that tracks window drags and triggers a merge on
  proximity, independent of what's inside each pane. Each pane just needs to conform to
  a common "joinable pane" protocol/interface (something like: provide a view, a
  title, and a way to detach itself back into a standalone window).
- Combinations to support: PDF + PDF (already works), Notes + PDF, Notes + Notes,
  PDF + main window, Notes + main window.
- **Main window is a special case** — it's normally a singleton. Decide how joining it
  works (e.g. it becomes one pane of the combined window, and while joined there's no
  separate standalone main window instance; un-joining restores it as the singleton
  again) and flag your approach clearly, since this is the trickiest part of the
  refactor.
- Un-joining: same mechanism as Session 9 (divider-drag-to-edge or a "split out"
  button), generalized to detach either pane back into its own standalone window
  regardless of content type.

## 2. Page earmarks (bookmarks)

- New table: `page_bookmark(id TEXT PRIMARY KEY, paper_id TEXT REFERENCES
  paper(id) ON DELETE CASCADE, page INTEGER NOT NULL)` — new migration.
- In the Session 6 thumbnail sidebar, add a bookmark toggle per page (small icon on
  the thumbnail, or a keyboard shortcut while that page is in view).
- Bookmarked pages show a small bookmark-ribbon icon in the top-right corner of their
  thumbnail, rendered in the macOS system accent color — reuse the same
  `NSColor.controlAccentColor` + live-update-on-theme-change approach from Session 12's
  notes indicator rather than reimplementing it.

## Non-goals

- No jump-to-next-bookmark navigation UI this session (fine to add if trivial, flag if
  you do)
- No persisting split-window layouts across app relaunch — snapping/joining state
  resets on quit, same as Session 9's original scope

## Constraints

- Keep the earmarking feature (page_bookmark table, sidebar UI) fully separable from
  the window-joining refactor in the diff — they're unrelated pieces of work bundled
  into one session for scheduling convenience, not because they share code.

## Deliverable

App builds and runs. I should be able to drag a notes window next to a PDF reader
window and have them join into one split view, drag a PDF reader next to the main
window and have that join too, and detach any joined pair back into standalone windows.
Separately, I should be able to bookmark a page from the thumbnail sidebar and see an
accent-colored ribbon on that thumbnail. Flag your approach to the main-window-as-pane
special case in detail — that's the part most likely to need revisiting later.
