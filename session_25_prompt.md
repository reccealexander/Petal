# Session 25: Comment Deletion, Comment Popup Resize Glitch, Focus Mode Exit Fix

## Agent Orchestration
If this session's usage crosses ~85% of budget before all tasks below are complete,
stop assigning further implementation work to Sonnet subagents. Instead, orchestrate
the remaining unfinished tasks using the local `codex` CLI (already installed on this
machine) as the implementing agent — hand off clearly scoped task descriptions to it
rather than continuing to consume Sonnet context. Finish the task currently in progress
before handing off, so nothing is left half-written with no assigned agent.

## Context

Continuing "Paper Reader." Three fixes: comments currently can't be deleted
independently of their highlight, the comment popup's resize (Session 21) is glitchy,
and exiting Focus Mode incorrectly returns to the main window instead of the reader.

## 1. Allow deleting a comment without deleting the highlight

Right now there's no way to remove just a `Comment` — deleting appears to only be
possible by removing the whole `Highlight` (which cascades and takes the comment with
it, per the schema's `ON DELETE CASCADE`). Add an explicit delete action for the
comment itself:
- From the comment popup (Session 3/21): a delete button/action that removes only the
  `Comment` row, leaving the underlying `Highlight` (and its color/selected text)
  fully intact on the page.
- After deleting the comment, the highlight should revert to its "no comment"
  visual state (per Session 3's "visual indicator for commented highlights" — the
  dot/border that distinguishes commented vs. plain highlights should disappear).
- Confirm before deleting, consistent with the confirmation pattern used for note and
  paper deletion elsewhere in the app.
- Reopening the popup on that highlight afterward should show an empty "add a comment"
  state, not a stale/broken reference to the deleted comment.

## 2. Fix: comment popup resizing is glitchy

Reproduce by resizing the comment popup (Session 21's resizable popup/window) across a
range of sizes and identify exactly what goes wrong — jumpiness, content reflow
stutter, the resize handle losing tracking, incorrect anchor repositioning relative to
the highlight as the size changes, etc. This is the same category of bug as Session
24's AI panel resize glitch — apply the same diagnostic approach: reproduce first,
identify the actual mechanism, then fix root cause rather than papering over symptoms.
Particular things to check given this popup is anchored to a highlight's on-screen
position (unlike the AI panel, which is just a split-view divider):
- Whether resizing is correctly recalculating the popup's anchor/arrow position
  relative to the highlight as dimensions change, or fighting with `NSPopover`'s own
  anchoring logic if that's still the underlying implementation from Session 21
- Whether the resize handle's drag tracking is being interrupted by other event
  handlers on the popup (e.g. the text field capturing drag events meant for the
  resize handle)
Confirm the fix by resizing repeatedly in both directions and confirming the popup
stays correctly anchored near its highlight throughout.

## 3. Fix: exiting Focus Mode should return to the reader, not the main window

Currently, exiting Focus Mode (via Escape or the View menu, per Session 14) incorrectly
sends the user back to the main library window instead of returning to the same PDF
reader window they were reading in, now back in normal (non-Focus-Mode) chrome. Fix
this so exiting Focus Mode:
- Keeps the same reader window in focus, simply restoring its normal toolbar/sidebar/
  chrome (reversing whatever Session 14 did to strip it down for Focus Mode)
- Does **not** bring the main library window to the front or change window focus to it
- Preserves the current page/scroll position exactly as it was in Focus Mode (no jump
  back to a previous position)
Likely cause: Focus Mode's enter/exit logic may be tied to window-level state that's
getting reset or misrouted on exit (e.g. exit accidentally calling a "go home"/"show
main window" path instead of purely toggling the reader window's own chrome
visibility) — find and fix the actual routing rather than adding a workaround that
re-opens the reader window after the fact.

## Non-goals

- No changes to how comments are created (Session 3's flow stays the same)
- No changes to Focus Mode's entry behavior or what it hides — only the exit-routing
  bug from Task 3
- No new resize-related features beyond fixing the existing glitch

## Deliverable

App builds and runs. A comment can be deleted independently, leaving its highlight
intact and reverting to the "no comment" visual state. The comment popup resizes
smoothly in both directions without losing its anchor to the highlight. Exiting Focus
Mode (Escape or View menu) returns to the same reader window at the same page/scroll
position, without ever surfacing the main library window. Flag the root causes found
for both the popup resize glitch and the Focus Mode exit routing bug.
