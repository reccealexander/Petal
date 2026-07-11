# Session 17: Resume Position, Reading Status, Highlight Taxonomy View

## Agent Orchestration
If this session's usage crosses ~85% of budget before all tasks below are complete,
stop assigning further implementation work to Sonnet subagents. Instead, orchestrate
the remaining unfinished tasks using the local `codex` CLI (already installed on this
machine) as the implementing agent — hand off clearly scoped task descriptions to it
rather than continuing to consume Sonnet context. Finish the task currently in progress
before handing off, so nothing is left half-written with no assigned agent.

## Context

Continuing "Paper Reader." Three related reading-quality-of-life features: precise
resume position per paper, a reading-status marker, and a way to browse highlights by
category across a paper or notebook rather than only encountering them inline.

## 1. Resume position

- New columns on `paper` (migration): `last_page INTEGER`, `last_scroll_offset REAL`
  (or whatever unit `PDFView` naturally exposes for vertical position within a page —
  use its native scroll/point representation rather than inventing a new coordinate
  system).
- On closing a reader window (or periodically while it's open, whichever is more
  reliable — flag which), persist the current page and scroll offset.
- On opening a paper, restore to that exact position instead of defaulting to page 1 —
  this is distinct from `last_opened_at` (Session 2), which just tracks recency; this
  tracks exactly where the user left off reading.
- First-ever open of a paper (no saved position yet) should default to page 1 as
  before.

## 2. Reading status

- New column on `paper`: `reading_status TEXT DEFAULT 'unread'` — values `unread`,
  `in_progress`, `read` (migration).
- Auto-transition `unread` → `in_progress` the first time a paper is opened. Never
  auto-transition to `read` — that's a manual user action only (e.g. a status
  dropdown/button in the reader toolbar, or a context-menu action on the paper card).
- Show the status somewhere visible on the paper card across view modes (a small
  dot/label is enough — reuse whatever minimal-badge pattern fits alongside the notes
  indicator and bookmark indicators from Sessions 12–13, don't invent a heavier UI
  element for this).
- Add status as a filter option on the home screen (alongside existing tag filters
  from Session 5/12) — e.g. "show only unread" or "show only in progress."

## 3. Highlight taxonomy view

- A new view (accessible from a paper's toolbar for paper-scope, and from a notebook's
  view for notebook-scope) that lists highlights grouped/filterable by color, rather
  than only being visible inline while scrolling the PDF.
- Paper-scope: show all of that paper's highlights, grouped by color, each entry
  showing the highlighted text snippet, page number, and linked comment (if any);
  clicking one jumps the reader to that highlight.
- Notebook-scope: same idea, aggregated across every paper in the notebook — group
  first by color, then by paper within each color group (or paper then color, your
  call — flag which grouping you used and why).
- This is a read/browse/jump view, not an editor — creating or editing highlights
  still happens in the PDF itself (Session 3), this view is purely for surfacing what
  already exists in a structured way.

## Non-goals

- No changes to how highlights are created or colored (Session 3's flow stays as-is)
- No automatic "read" detection (e.g. based on scroll-to-end or time spent) — status
  changes to `read` are manual only
- No new AI-generated content this session — this is pure data/UI work

## Constraints

- Reuse the accent-color/badge conventions established in Sessions 12–13 for any new
  card-level indicators (reading status, etc.) rather than introducing a new visual
  language.
- Keep resume-position writes lightweight (don't write to the DB on every scroll
  tick — debounce or write-on-close, consistent with the autosave debounce pattern
  from Session 4's notes editor).

## Deliverable

App builds and runs. Reopening a paper returns you to the exact page/scroll position
you left it at, not page 1. Papers show a reading-status indicator that auto-advances
to "in progress" on first open and can be manually marked "read," with a home-screen
filter for status. A highlight taxonomy view — at both paper and notebook scope — lists
highlights grouped by color with jump-to-highlight behavior. Flag your choice on
resume-position write timing and the notebook-scope grouping order.
