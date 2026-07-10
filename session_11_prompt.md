# Session 11: Selection Model + PDF Management

## Agent Orchestration
If this session's usage crosses ~85% of budget before all tasks below are complete,
stop assigning further implementation work to Sonnet subagents. Instead, orchestrate
the remaining unfinished tasks using the local `codex` CLI (already installed on this
machine) as the implementing agent — hand off clearly scoped task descriptions to it
rather than continuing to consume Sonnet context. Finish the task currently in progress
before handing off, so nothing is left half-written with no assigned agent.

## Context

Continuing "Paper Reader." This session changes how paper cards are clicked/selected
on the home screen and adds deletion + tag-autocomplete.

## 1. Click-to-select, click-again-to-open

Currently a single click on a paper card opens it. Change this:
- Clicking an **unselected** card selects it (visible selection state — border/
  highlight) but does not open it.
- Clicking an **already-selected** card opens it (same reader-window behavior as
  before).
- Clicking empty space in the grid/list deselects everything.

## 2. Shift-click multi-select + ⌘O to open together

- Shift-clicking a second card extends the selection to include it (range-select
  behavior like Finder: if the cards are visually ordered, shift-click selects
  everything between the last-selected and the new one; simple additive multi-select
  is also acceptable if range logic is complex — flag which you implemented).
- With 2+ papers selected, `⌘O` opens them together side-by-side, reusing the
  dual-pane window mechanism from Session 9 (or its "Compare side-by-side" fallback if
  that's what was ultimately built). If more than 2 are selected, decide and flag how
  you handled it (e.g. open the first two together and the rest as individual windows,
  or restrict ⌘O to exactly 2 selected with a subtle UI cue when the count is wrong).

## 3. Delete PDFs

- Delete action available from selected paper card(s) — context menu item and/or
  ⌘⌫/Delete key.
- Deleting a paper should: remove the `Paper` row, delete its copied PDF file and
  cached thumbnail from disk, and cascade per the existing schema (highlights,
  comments, notes, chat sessions tied to that paper all go with it — this already
  cascades at the DB level per Session 1's foreign keys, just confirm it actually
  fires and doesn't leave orphaned files on disk).
- Confirm before deleting (alert, mentions how many papers if multiple selected),
  same pattern as note deletion from Session 8.

## 4. Tag autocomplete dropdown

When adding a tag to a paper, replace free-text-only entry with a dropdown/autocomplete
showing existing `Tag` rows as the user types, so tags stay consistent instead of
near-duplicates ("2D materials" vs "2d-materials") accumulating. Still allow creating a
genuinely new tag if nothing matches what's typed.

## Non-goals

- No changes to notebook/folder structure itself (Session 12)
- No changes to view modes (Session 12)
- No undo for deletion beyond the confirmation dialog

## Constraints

- Selection state is transient UI state (not persisted to the DB) — clears on app
  relaunch, that's fine.
- Keep the click-vs-open logic centralized (e.g. in the grid's selection controller)
  rather than duplicated across grid and any future list/free-space views from
  Session 12 — those views will need to reuse this same selection behavior.

## Deliverable

App builds and runs. Single click selects a card, clicking a selected card opens it,
shift-click extends selection, ⌘O with 2 selected opens them side-by-side, delete
removes a paper (file + DB row + cascaded children) with confirmation, and adding a tag
shows a dropdown of existing tags with the option to create new ones. Flag your choice
on multi-select-beyond-2 behavior for ⌘O and on range vs. additive shift-click.
