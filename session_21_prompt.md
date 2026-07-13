# Session 21: Sidebar Menu Cleanup + Resizable Comment Popup

## Agent Orchestration
If this session's usage crosses ~85% of budget before all tasks below are complete,
stop assigning further implementation work to Sonnet subagents. Instead, orchestrate
the remaining unfinished tasks using the local `codex` CLI (already installed on this
machine) as the implementing agent — hand off clearly scoped task descriptions to it
rather than continuing to consume Sonnet context. Finish the task currently in progress
before handing off, so nothing is left half-written with no assigned agent.

## Context

Continuing "Paper Reader." Two small, unrelated fixes this session.

## 1. Sidebar menu: duplicate "All Papers" section

The sidebar/menu currently shows **two separate "All Papers" sections**, which
doesn't make sense. Investigate why there are two (likely candidates: one was added
as part of the original notebook tree in Session 5 and a second was introduced
alongside the All Folders work in Session 12 without removing the first, or one is a
leftover from an earlier iteration that never got cleaned up). Remove the duplicate,
keeping exactly one "All Papers" entry that shows every paper regardless of notebook.

While fixing this, also move the **"Unfiled"** section (papers with no notebook
assigned) up in the sidebar ordering — it should sit near the top, alongside/near "All
Papers" and Pinned items, rather than wherever it currently falls in the list. Confirm
the final sidebar ordering makes sense top-to-bottom (e.g. Pinned → All Papers →
Unfiled → notebook tree, or similar — use your judgment on exact order, but the two
"All Papers" sections must become one, and "Unfiled" must move up from its current
position).

## 2. Resizable comment popup

The comment popover (Session 3, anchored to a highlight) currently has a fixed size.
Make it resizable — the user should be able to drag an edge/corner to make the popover
larger (for longer comments) or smaller, similar to how a normal resizable window or
text box works. `NSPopover` doesn't support user-resizing out of the box, so this
likely requires either:
- Embedding a manually resizable container view inside the popover with a drag handle
  in one corner, or
- Switching this specific UI element from an `NSPopover` to a lightweight borderless
  `NSWindow` that supports native resizing (`styleMask` including `.resizable`),
  positioned/anchored the same way the popover currently is

Pick whichever approach is more reliable given how the popover is currently
implemented — flag which one you used and why. Preserve existing behavior: it should
still appear anchored near the highlight, still save/cancel the same way, and editing
an existing comment should still pre-fill as before (Session 3's behavior).

## Non-goals

- No other sidebar reorganization beyond removing the duplicate and moving Unfiled up
- No changes to comment content/behavior beyond making the popup resizable
- No persistence of the comment popup's resized dimensions across app sessions —
  resetting to a default size each time it's reopened is fine

## Deliverable

App builds and runs. The sidebar shows exactly one "All Papers" section, with
"Unfiled" moved up near the top. The comment popup can be resized by the user (drag to
expand/shrink) while keeping its existing anchor, save/cancel, and pre-fill behavior
intact. Flag the root cause found for the duplicate "All Papers" section and which
resizing approach you used for the popup.
