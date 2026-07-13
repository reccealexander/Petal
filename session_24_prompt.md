# Session 24: Panel Resize Glitch, Adjustable Chat Font, Context Token Usage

## Agent Orchestration
If this session's usage crosses ~85% of budget before all tasks below are complete,
stop assigning further implementation work to Sonnet subagents. Instead, orchestrate
the remaining unfinished tasks using the local `codex` CLI (already installed on this
machine) as the implementing agent — hand off clearly scoped task descriptions to it
rather than continuing to consume Sonnet context. Finish the task currently in progress
before handing off, so nothing is left half-written with no assigned agent.

## Context

Continuing "Paper Reader." Session 23 made the AI chat panel resizable and fixed
markdown rendering in its responses. This session: fix the resize interaction (it's
currently glitchy), add font/size controls for chat responses, and stop the panel from
burning tokens on paper/notebook context for questions that don't need it.

## 1. Fix: chat panel resize is glitchy

Reproduce by dragging the AI panel's divider (Session 23) across a range of widths and
observe what actually goes wrong — jumpiness, lag, content reflow stutter, the divider
losing track of the cursor, flicker, or the panel snapping to unexpected widths.
Capture what specifically is glitchy before fixing (don't guess blind). Likely causes
to check:
- The persisted-width-on-relaunch logic from Session 23 also firing/writing on every
  drag tick instead of only on drag-end, causing redundant layout passes mid-drag
- Chat message content (especially the newly-added markdown rendering from Session 23)
  re-laying-out expensively on every divider movement instead of only when the drag
  finishes
- Conflicting width constraints between the min/max clamping added in Session 23 and
  AppKit's own split-view resize handling, fighting each other during the drag
Fix the actual cause found; confirm by dragging the divider rapidly across its full
range multiple times and checking it tracks the cursor smoothly with no stutter.

## 2. Adjustable chat response font and size

- Add a font family and size control for the AI panel's chat messages — a settings
  section (Settings → Appearance, alongside the transparency slider and reading-
  progress toggle) is the right place, consistent with where other appearance controls
  already live.
- This is separate from Session 23's rich-text note formatting — notes keep their own
  per-note formatting; this control sets one global font/size for all chat message
  rendering in the panel.
- Apply immediately to the panel when changed, and persist across relaunches.

## 3. Reduce token usage: don't include paper/notebook context unless asked

Right now `ContextBuilder` (Session 6/7) likely assembles full paper or notebook
context on every message sent, even for questions that have nothing to do with the
paper (e.g. "what's 15% of 340" or "rewrite this sentence to be more concise"). That
wastes tokens and money on every single message.

**Recommended approach — explicit toggle, not automatic intent-guessing:** add a
visible toggle/control in the chat panel (e.g. "Include paper context" / "Include
notebook context," matching whichever scope is active) that the user sets explicitly,
rather than trying to infer from the question's wording whether context is needed.
Automatic detection would require either a second model call to classify intent
(which defeats the purpose — you'd be spending tokens to save tokens) or a fragile
keyword heuristic that will misfire constantly. An explicit toggle is simpler, cheaper,
and puts the control where the user can see exactly what's happening.

- Default state: your call — either default ON (matches current always-include
  behavior, safest for not breaking existing conversations) or default OFF (matches
  the spirit of "don't use context unless asked") — flag which you chose and why.
- When OFF: send only the conversation history and the user's message, no PDF text, no
  highlights/comments/notes, no notebook aggregation — a plain general-purpose chat.
- When ON: behaves exactly as `ContextBuilder` does today (Sessions 6/7's paper-scope
  or notebook-scope assembly).
- Make the current state visually obvious in the panel at all times (not just at the
  moment of toggling) so the user always knows whether their next message will include
  paper context or not.
- Existing `ChatSession` persistence (Session 6) should keep working regardless of
  toggle state — a conversation can mix context-included and context-excluded messages
  if the user flips the toggle mid-conversation; that's fine, don't try to prevent it.

## 4. Access the chatbot from Focus Mode

Focus Mode (Session 14) strips away the main reader chrome, including the AI panel —
there's currently no way to reach the chatbot while in Focus Mode. Fix this by adding
another button to the expandable/movable toolbar built in Session 19 (the one that
already has Notes and Highlights controls). This new button opens the AI chat in a
**separate standalone window** rather than trying to dock the panel back into the
(intentionally minimal) Focus Mode view.

- Reuse the existing `ClaudePanelView` and its chat/context logic (Session 6/7, plus
  this session's font controls and context toggle) inside that standalone window
  rather than building a second chat implementation.
- The window should be a normal, independently movable/resizable `NSWindow` — it's not
  bound by Focus Mode's transparency rules, since it's a separate window sitting
  outside the stripped-down reader chrome, not an overlay on top of the PDF.
- Opening this window should not exit Focus Mode — the PDF stays in its minimal Focus
  Mode state, the chat window simply floats alongside it.
- Closing the chat window should not exit Focus Mode either — the two are independent;
  only Escape or the View menu (Session 14) exits Focus Mode.
- Whichever chat session (paper-scope or notebook-scope, per Session 7) was active
  before entering Focus Mode should carry over into this window, rather than starting
  a blank conversation.

## Non-goals

- No automatic/AI-based detection of whether a question "needs" context — explicit
  toggle only, per the recommendation above
- No per-message context override UI beyond the single toggle (no granular "include
  just highlights but not full text" controls this session)
- No changes to the quick-action buttons from Session 7 — those can continue to force
  context inclusion when invoked, regardless of the toggle's current state, since
  they're explicitly context-dependent actions by nature

## Deliverable

App builds and runs. Dragging the AI panel's divider is smooth with no stutter/glitch
across its full range. Chat message font family and size are adjustable from Settings
and persist. A visible toggle controls whether paper/notebook context is sent with
messages, defaulting to whichever state you chose and flagged, with the current state
always clear to the user. The Focus Mode toolbar has a new button that opens the
chatbot in a standalone window without exiting Focus Mode, carrying over whatever chat
session was already active. Flag the root cause found for the resize glitch and your
default-state decision for the context toggle.
