# Session 16: Transparency Crash (Take 2), Keyboard Navigation, Free Space Layout Fix

## Agent Orchestration
If this session's usage crosses ~85% of budget before all tasks below are complete,
stop assigning further implementation work to Sonnet subagents. Instead, orchestrate
the remaining unfinished tasks using the local `codex` CLI (already installed on this
machine) as the implementing agent — hand off clearly scoped task descriptions to it
rather than continuing to consume Sonnet context. Finish the task currently in progress
before handing off, so nothing is left half-written with no assigned agent.

## Context

Continuing "Paper Reader." Session 14 added the transparency slider and Focus Mode.
Session 15 was scoped to fix a blank-main-window regression and a transparency-slider
crash from Session 14, alongside a Quick Tips window. This session confirms the
transparency crash is **still not fixed** — it now fully quits the app, not just a
visible glitch — and adds two more items: arrow-key navigation between selected papers,
and a layout fix for Free Space mode plus a scope change to how Graph mode is reached.

## 1. Transparency crash — full app termination (highest priority, fix first)

This is now confirmed to **quit the app entirely**, not just glitch the UI. Treat any
prior attempted fix (Session 15, Task 0) as insufficient — do not repeat the same
approach without first getting a real crash log.

1. Reproduce by launching fresh, opening Preferences, and dragging the transparency
   slider across its range. Capture the actual crash log (Console.app crash report or
   Xcode's debugger stack trace at the point of the fatal error) — don't guess at the
   cause without it.
2. Read the stack trace to find the exact line/function that crashes. Common root
   causes for this class of bug, to check against what the trace actually shows:
   - A force-unwrap (`!`) on an `NSVisualEffectView`, window, or layer reference that's
     `nil` during some part of the slider's live-update path
   - An `NSVisualEffectView` material or blending mode being set to an invalid/
     unsupported value at a particular alpha extreme (e.g. exactly 0 or exactly 100)
   - A retain-cycle or over-release on the chrome/content layer split introduced in
     Session 14 — check that both layers are being retained correctly as the window's
     view hierarchy updates on each slider tick
   - The slider firing far more update events than expected (e.g. on every pixel of
     drag rather than debounced) and some downstream call not being safe to call that
     rapidly
3. Fix the actual cause. After fixing, stress-test it: drag the slider rapidly back
   and forth across the full range multiple times, not just once slowly, before
   considering this done.

## 2. Arrow-key navigation between papers

- With a paper selected (per Session 11's selection model), the **left/right arrow
  keys** (or up/down, whichever reads more naturally for the active view mode — flag
  which you used, and use left/right for Grid/Free Space/Graph and up/down for List if
  that fits better) move the selection to the adjacent paper.
- This should work across whichever view mode is currently active (Grid, List, Free
  Space) — "adjacent" means visually adjacent in that mode's current layout, not a
  fixed underlying order.
- Pressing Return/Enter on the currently-selected paper should open it (equivalent to
  clicking an already-selected card), giving a full keyboard-only flow: arrow to
  select, Enter to open.

## 3. Free Space mode: fix oversized canvas, fold Graph into a toggle

Two related fixes to the Free Space view from Session 12:

1. **Canvas sizing bug:** currently the Free Space canvas is larger than the visible
   window, so some papers end up positioned outside the visible area and are only
   reachable by scrolling/panning around. Fix this so the draggable canvas is
   constrained to the same size as the window itself — papers can be dragged anywhere
   within the visible window bounds, not into an off-screen area. If a paper's
   currently-saved `free_space_x`/`free_space_y` position (from Session 12) falls
   outside the new bounds, clamp it back into view rather than leaving it
   unreachable.
2. **Graph mode becomes a toggle, not a separate page:** Session 12 built Graph as a
   4th swipeable page. Remove it as a separate page — the paging should go back to
   3 pages (Grid, List, Free Space), and the bottom dot indicator should reflect 3
   dots, not 4. Instead, add a toggle button directly on the Free Space page (e.g. in
   its toolbar) that switches Free Space between normal mode and graph mode. Graph
   mode overlays connecting lines between papers that share at least one tag (reuse
   the paper-as-node, shared-tag-as-edge logic already built in Session 12 — this is a
   presentation-mode toggle on top of the same canvas, not a new page or a new
   underlying data model).

## Non-goals

- No changes to Grid or List mode layouts
- No new tag/graph data model changes — Task 3's graph toggle reuses Session 12's
  existing paper/tag data as-is
- No animated transitions for the toggle beyond a simple show/hide of the connecting
  lines

## Deliverable

App builds and runs. Dragging the transparency slider across its full range, rapidly
and repeatedly, does not crash or quit the app. Arrow keys move selection between
papers in whichever view mode is active, and Enter opens the selected one. Free Space
mode's canvas matches the window size (no off-screen papers), paging is back to 3
pages/3 dots, and a toggle button on the Free Space page switches graph mode on/off.
Flag the actual root cause found for the transparency crash — that's the most important
finding to report back on given this is the second attempt at it.
