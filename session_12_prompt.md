# Session 12: View Modes, All Folders, Pinning, Notes Indicator

## Agent Orchestration
If this session's usage crosses ~85% of budget before all tasks below are complete,
stop assigning further implementation work to Sonnet subagents. Instead, orchestrate
the remaining unfinished tasks using the local `codex` CLI (already installed on this
machine) as the implementing agent — hand off clearly scoped task descriptions to it
rather than continuing to consume Sonnet context. Finish the task currently in progress
before handing off, so nothing is left half-written with no assigned agent.

## Context

Continuing "Paper Reader." This is the most involved session so far — four related
pieces of work around how the home screen presents papers and notebooks. Reuse the
selection model from Session 11 across every view mode below rather than
reimplementing it per-view.

## 1. Multiple view modes for the paper grid

Four modes, switched via **horizontal swipe** (two-finger trackpad gesture) rather
than a button, with a **row of dots at the bottom** indicating which page/mode is
active (iOS-style paging) — this is nonstandard for a Mac app, but that's the request;
implement it with a horizontal `NSScrollView` in paging mode or a custom swipe gesture
recognizer, whichever is more reliable.

- **Grid** (current): thumbnail cards, as it already works today.
- **List:** text-only rows — title, page count, tags — no thumbnails. Same
  click-to-select/click-to-open and shift-click behavior as Grid.
- **Free Space:** papers can be dragged anywhere within an open canvas and stay where
  dropped. Requires new columns (e.g. `paper.free_space_x`, `paper.free_space_y`,
  nullable — null means "not yet placed, default to some layout"). Position persists
  across app relaunch.
- **Graph:** a sub-toggle within Free Space mode. **Scoping note:** the request is
  "notes are nodes and lines are tags shared" — but tags currently attach to papers
  (`paper_tag`), not notes, and there's no `note_tag` table. Default to treating
  **papers as the graph nodes** (reusing existing `paper_tag` data, no schema change)
  with edges drawn between papers that share at least one tag. If literal per-note
  tagging is actually wanted, that requires a new `note_tag` join table and tagging
  UI on notes themselves — flag this explicitly as a scope question rather than
  guessing; build the paper-based version for this session either way so there's a
  working graph view, and note what a note-based version would additionally require.

## 2. All Folders menu

A new top-level view listing every notebook. Each notebook's thumbnail: one
representative paper's thumbnail from inside that notebook (e.g. the most recently
added, or the pinned one if Task 3 below results in a pinned paper — your call, flag
which), rendered with a **stacked-papers effect** — 2–3 offset rectangles with drop
shadows behind the top thumbnail, so it visually reads as a pile of papers rather than
a single flat image.

## 3. Pinning

- Pin a paper within a notebook (pins to the top of that notebook's paper listing,
  across all four view modes).
- Pin a notebook within All Folders (pins to the top of the All Folders listing).
- New nullable `pinned_at DATETIME` columns on both `paper` and `notebook` (new
  migration). Sort: pinned items first (by `pinned_at`, most-recently-pinned first or
  oldest-first — your call, flag it), then unpinned items in whatever the existing
  default order is.
- Pin/unpin via context menu on a card (any view mode) or on a notebook in All Folders.

## 4. Notes indicator

A small badge/icon on any paper card (all four view modes, adapted appropriately — a
small icon in List mode, an overlay on the thumbnail in Grid/Free Space) shown only if
that paper has at least one note. Render it in the macOS system accent color
(`NSColor.controlAccentColor`) so it matches whatever theme color the user has set in
System Settings, and updates live if they change it while the app is running (listen
for the relevant appearance-change notification rather than reading the color once at
launch).

## 5. Fix: shift-click should select exactly two, not a range

Session 11 implemented shift-click as Finder-style range select (everything between
the last-selected card and the new one). That's not the intended behavior — change it
so shift-clicking selects **only** the previously-selected card and the newly-clicked
card (exactly two selected total), not anything visually between them. If more than
one card was already selected when shift-click happens, decide and flag how you handle
it (simplest: shift-click always collapses selection down to just {the single most
recently selected card, the newly clicked card}).

## 6. Fix: repeated Keychain prompts for the Gemini key

Currently, opening a PDF triggers a macOS Keychain access prompt — "Paper Reader wants
to use confidential information stored in com.paperreader.googleaistudio in your
Keychain" — repeatedly, on every open, instead of once. This needs an actual root-cause
fix, not a workaround. Investigate these likely causes, in order:

1. **Unnecessary read on the hot path:** check whether opening a `PDFReaderView`
   somehow triggers a Gemini/notebook-summary check (Session 10 logic) that it
   shouldn't — that trigger should only fire on new-note creation, not on paper open.
   If it's being read here at all, that's likely the actual bug — remove the read from
   this path entirely.
2. **Keychain item access control:** confirm the Gemini key's `SecItemAdd` call sets a
   stable `kSecAttrAccessible` value (e.g. `kSecAttrAccessibleAfterFirstUnlock`) and
   isn't requiring per-access UI confirmation. A well-configured item, once the user
   clicks "Always Allow" a single time, should not prompt again for the life of that
   keychain entry.
3. **Code-signing stability:** if the app is being rebuilt/re-run frequently from
   Xcode with ad-hoc/dev signing (per Session 5's packaging notes), the app's signature
   can change between builds, which invalidates the Keychain ACL that was tied to the
   previous signature — macOS then treats it as a new, unrecognized requester and
   re-prompts. If this is the cause, note it clearly: it may mean the prompt only
   *appears* fixed in a stable Release build and will resurface any time the app is
   rebuilt during development. Don't hide this tradeoff — tell me plainly if this is
   what's happening.

Fix whichever of these is the actual cause; don't just suppress the symptom. Confirm
the fix by opening several different papers in a row without a repeated prompt.

## Non-goals

- No note-level tagging unless you determine it's trivial (see Task 1's flag)
- No drag-and-drop reordering *within* List mode beyond what pinning already provides
- No animated transitions between view modes beyond whatever the swipe gesture
  naturally gives you

## Deliverable

App builds and runs. Swiping between Grid/List/Free Space/Graph works with a
bottom dot indicator, papers can be freely positioned in Free Space and persist, Graph
mode shows papers as nodes connected by shared tags, All Folders shows every notebook
with a stacked-thumbnail treatment, pinned papers/notebooks sort to the top everywhere
relevant, and papers with notes show an accent-colored badge across all view modes.
Shift-click selects exactly two cards, never a range. Opening PDFs no longer triggers
repeated Keychain prompts. Flag the graph-view scoping decision, the pin sort-order
choice, the representative-thumbnail choice for All Folders, and — importantly — the
actual root cause you found for the Keychain prompt bug.
