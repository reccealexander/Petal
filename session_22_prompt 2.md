# Session 22: Progressive Reading-Progress Border on Thumbnails

## Agent Orchestration
If this session's usage crosses ~85% of budget before all tasks below are complete,
stop assigning further implementation work to Sonnet subagents. Instead, orchestrate
the remaining unfinished tasks using the local `codex` CLI (already installed on this
machine) as the implementing agent — hand off clearly scoped task descriptions to it
rather than continuing to consume Sonnet context. Finish the task currently in progress
before handing off, so nothing is left half-written with no assigned agent.

## Context

Continuing "Paper Reader." Session 17 added a reading-status indicator (unread / in
progress / read, shown as a small badge/dot on the card). Replace that visual with a
**progressive colored line that wraps around the thumbnail's border**, filling in
proportionally to how much of the paper has been read — fully enclosing the thumbnail
once the paper has been read to the end.

## 1. Track reading progress (furthest page reached)

- New column on `paper`: `furthest_page_read INTEGER DEFAULT 0` (migration).
- On the same debounced write used for Session 17's resume-position tracking, update
  this to `max(furthest_page_read, current_page)` — this should only ever increase, it
  tracks the furthest point reached, not the current scroll position (which can move
  backward if the user re-reads earlier pages).
- Progress fraction = `furthest_page_read / page_count`, clamped to [0, 1].

## 2. Progressive border visual

- Replace the Session 17 status badge/dot with a border stroke around the thumbnail
  that progressively "wraps" the rectangle's perimeter as the fraction increases —
  think of it like a loading/progress ring, but tracing the rectangle's edge instead
  of a circle (start at a fixed corner, e.g. top-left, and proceed clockwise).
- At 0% (unread, `furthest_page_read == 0`): no border, or an extremely faint neutral
  outline — your call, flag which.
- At 100% (furthest page reached == last page): the border fully encloses the
  thumbnail, all four edges complete.
- Use the macOS system accent color (`NSColor.controlAccentColor`) for the stroke,
  consistent with the notes-indicator and bookmark-ribbon conventions from Sessions
  12–13 — reuse that same accent-color/live-theme-update helper rather than
  reimplementing it.
- Apply this across every view mode that shows a thumbnail (Grid, Free Space) — List
  mode has no thumbnail, so show a compact version there instead (e.g. a small
  percentage-filled bar or arc next to the title) rather than omitting progress
  entirely.

## 3. Relationship to Session 17's manual reading-status field

Keep Session 17's `reading_status` column (`unread` / `in_progress` / `read`) and its
home-screen filter working exactly as before — this session does **not** remove or
replace that filtering mechanism. The two systems coexist:
- `reading_status`: manual, user-controlled, used for filtering
- `furthest_page_read` / progress border: automatic, purely visual, reflects actual
  reading progress

Auto-set `reading_status` to `read` when the progress border reaches 100%

## Non-goals

- No changes to the manual status filter UI itself (still unread/in-progress/read)
- No animation requirements beyond the border reflecting the current fraction — a
  smooth fill animation on load is a nice-to-have, not required
- No per-page read-tracking granularity beyond "furthest page reached" (e.g. no
  tracking of which specific pages were skipped vs. actually viewed)

## Deliverable

App builds and runs. Thumbnails in Grid and Free Space mode show a progressive
accent-colored border that grows as more of the paper is read, fully enclosing the
thumbnail once the last page has been reached; List mode shows an equivalent compact
progress indicator. The existing manual reading-status filter from Session 17 still
works unchanged. Flag your choice on the 0%-state appearance and confirm whether you
kept `reading_status` fully manual or linked it to progress completion.
