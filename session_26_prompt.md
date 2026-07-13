# Session 26: Gemini Rate Limit Bug + Chat Session Management

## Agent Orchestration
If this session's usage crosses ~85% of budget before all tasks below are complete,
stop assigning further implementation work to Sonnet subagents. Instead, orchestrate
the remaining unfinished tasks using the local `codex` CLI (already installed on this
machine) as the implementing agent — hand off clearly scoped task descriptions to it
rather than continuing to consume Sonnet context. Finish the task currently in progress
before handing off, so nothing is left half-written with no assigned agent.

## Context

Continuing "Paper Reader." Two pieces: a real bug causing the Gemini free tier to rate
-limit almost immediately, and new chat-management features (delete individual chats,
start a fresh conversation) for the LLM panel.

## 1. Fix: Gemini free tier rate limit hit immediately

The user is on Google AI Studio's free tier and is getting rate-limited right away,
which shouldn't happen under normal single-user usage. Investigate these, in order:

1. **Wrong model tier.** Confirm exactly which Gemini model `GeminiClient` (Session
   10) is configured to call. As of the free tier's current state, **Gemini 2.5 Pro is
   paid-only** — there is effectively no free quota for it. If the client is pointed
   at a Pro model, switch the default to a Flash-tier model (e.g. Gemini 2.5 Flash or
   Flash-Lite), which have real, usable free-tier request budgets (roughly 10–15
   requests/minute, ~1,500/day, subject to change — don't hardcode exact numbers into
   logic, just pick a Flash-tier model as the default).
2. **Runaway trigger bug (most likely root cause).** Session 10's notebook-summary
   logic is supposed to call Gemini only when a **new note** is created in a notebook.
   Check whether it's actually keyed off note *creation* specifically, or whether it's
   accidentally firing on Session 4/23's **debounced autosave** (which runs repeatedly
   while the user is just typing/editing an existing note, not creating a new one).
   If the trigger is wired to the autosave path rather than genuine note-creation
   events, that would call the Gemini API many times per minute during normal note-
   taking — which would exhaust even a generous free-tier RPM budget almost instantly
   and is the most likely explanation for "immediate" rate limiting. Fix so the
   summary trigger fires only on actual new-note creation, exactly as Session 10
   originally specified.
3. **Redundant/duplicate calls.** While investigating, check for any other place that
   might be calling `GeminiClient` more than once per logical action (e.g. a retry
   without backoff, a request fired from more than one place for the same event).
4. **Token volume.** Separately from request count, confirm notebook summaries aren't
   sending more than necessary — Session 10 specified sending notebook papers/notes
   text, not full raw PDF text; confirm that's still the case and hasn't crept up in
   scope since.

After fixing, verify by taking notes in a notebook for a few minutes (creating and
editing notes) and confirming Gemini calls only fire on genuine new-note events, not
on every autosave tick.

## 2. Chat session management (LLM panel)

- **Delete individual chats:** in the AI panel (Session 6/7/24), allow deleting a
  specific `ChatSession` — e.g. from a chat-history list/picker if one exists, or a
  delete action in the panel itself. Deleting removes that `ChatSession` row and its
  messages; it should not affect the paper/notebook's highlights, comments, or notes
  in any way — this only touches chat history.
- **Start a completely fresh conversation:** a distinct action ("New Chat" / "Clear
  Conversation") that starts a blank conversation for the current paper/notebook scope
  without necessarily deleting the previous one — decide and flag whether this creates
  a new `ChatSession` row (preserving the old one, accessible later if a history list
  exists) or clears the current session's messages in place (destructive, old messages
  gone). Prefer creating a new session over destructive clearing if that's not
  significantly more work, since it preserves history without extra cost — flag which
  you implemented.
- Make sure this works correctly for both paper-scope and notebook-scope conversations
  (Session 7), and inside the standalone Focus Mode chat window (Session 24) as well
  as the docked panel.

## Non-goals

- No changes to the context-inclusion toggle from Session 24
- No chat export/backup this session
- No changes to the Claude-side chat flow beyond whatever shared UI/logic is reused
  for consistency — this task list is Gemini-focused for the bug fix, but the delete/
  new-chat UI should work for both providers since Session 20 made the provider
  choice switchable

## Deliverable

App builds and runs. Taking notes for several minutes no longer triggers repeated
Gemini calls — only genuine new-note events do, and the client defaults to a
Flash-tier free model rather than Pro. The AI panel supports deleting an individual
past chat and starting a fresh conversation, working across paper-scope, notebook-
scope, and the Focus Mode standalone chat window. Flag the actual root cause found for
the rate-limit bug and your decision on new-chat-as-new-session vs. destructive clear.
