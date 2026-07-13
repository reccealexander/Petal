# Session 32: Notebook Drag-and-Drop, Move-To Menu, Subfolder Thumbnails

## Agent Orchestration
If this session's usage crosses ~85% of budget before all tasks below are complete,
stop assigning further implementation work to Sonnet subagents. Instead, orchestrate
the remaining unfinished tasks using the local `codex` CLI (already installed on this
machine) as the implementing agent — hand off clearly scoped task descriptions to it
rather than continuing to consume Sonnet context. Finish the task currently in progress
before handing off, so nothing is left half-written with no assigned agent.

## Context

Continuing "Paper Reader." Session 12 built the notebook sidebar tree with basic
nesting and drag-a-paper-onto-a-notebook support. This session rounds out the
organization workflow: moving subfolders out of their parent, dragging papers both
into and out of folders, a right-click "Move to" alternative to drag-and-drop, and
showing subfolders as visual cards (with the stacked-thumbnail treatment) inside their
parent notebook's view.

## 1. Drag a subfolder out of its parent

In the left sidebar's notebook tree, dragging a nested notebook out of its current
parent should move it — to the root level (top of the tree, no parent) if dropped in
open sidebar space, or into a different notebook if dropped directly onto one. This
extends Session 12's existing "drag a notebook onto another to nest it" — the missing
piece is un-nesting / re-parenting, not just nesting deeper. Update `notebook.parent_id`
accordingly (set to `NULL` for a move to root).

## 2. Drag papers to and from folders in the sidebar

- Confirm Session 12's "drag a paper card onto a notebook" still works from the sidebar
  specifically (not just from the main grid), and fix if it's degraded.
- Add the reverse: dragging a paper **out** of a notebook — e.g. dragging it onto the
  "Unfiled" or "All Papers" sidebar entry — sets `paper.notebook_id` to `NULL`,
  removing it from its current notebook without deleting the paper itself.
- Dragging a paper directly from one notebook onto a different notebook (in the
  sidebar, or from the main grid onto a sidebar entry) should move it in one step
  rather than requiring an unfile-then-refile sequence.

## 3. Right-click "Move to" menu as a drag-and-drop alternative

Add a "Move to…" submenu to the right-click context menu on a paper card (any view
mode), listing all existing notebooks (respecting the tree structure — nested
notebooks shown indented or in some clearly hierarchical way) plus an "Unfiled" option
at the top. Selecting one moves the paper there — same underlying action as the drag
gestures above, just a non-drag way to do it. This should also work with multi-select
(Session 11) — if multiple papers are selected, "Move to" applies to all of them.

## 4. Subfolders appear with thumbnails inside their parent notebook

When viewing a notebook's contents (in any of the view modes from Session 12 — Grid,
List, Free Space), its **subfolders should appear alongside its papers**, not just be
reachable via the sidebar tree. A subfolder's card should use the same
stacked-thumbnail treatment built for All Folders in Session 12 (representative
paper's thumbnail, offset rectangles behind it suggesting a pile) — reuse that
component directly rather than rebuilding it. Clicking a subfolder card navigates into
it, same as clicking one in the sidebar or in All Folders would.

## Non-goals

- No changes to the All Folders top-level view itself (Session 12) beyond reusing its
  thumbnail component — this task is about subfolders appearing *within* their
  parent's own view, which is a different context
- No drag-and-drop reordering of papers *within* a notebook beyond what pinning
  (Session 12) already provides
- No bulk "Move to" beyond what multi-select (Session 11) already selects — no new
  selection mechanism

## Deliverable

App builds and runs. Subfolders can be dragged out of their parent (to root or another
notebook) in the sidebar. Papers can be dragged into and out of notebooks, including
directly between two notebooks. A right-click "Move to" menu offers the same
capability without drag-and-drop, respecting multi-select. Opening a notebook shows
its subfolders as cards (with stacked-thumbnail styling) alongside its papers, not just
in the sidebar tree. Flag any edge cases you found tricky — particularly around moving
a subfolder that itself contains papers or further subfolders.
