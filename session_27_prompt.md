# Session 27: Gemini Model Fix

## Agent Orchestration
If this session's usage crosses ~85% of budget before all tasks below are complete,
stop assigning further implementation work to Sonnet subagents. Instead, orchestrate
the remaining unfinished tasks using the local `codex` CLI (already installed on this
machine) as the implementing agent — hand off clearly scoped task descriptions to it
rather than continuing to consume Sonnet context. Finish the task currently in progress
before handing off, so nothing is left half-written with no assigned agent.

## Context

Continuing "Paper Reader." Single focused fix this session: `GeminiClient` (Session
10) is hitting a 404 — "This model models/gemini-2.5-flash is no longer available."
This is a known, currently-active issue affecting `gemini-2.5-flash` and
`gemini-2.5-flash-lite` broadly as of July 2026, separate from anything specific to
this app.

## Goal for this session

1. Confirm exactly which Gemini model `GeminiClient` currently calls.
2. Switch the default to a current 3.x-line model — `gemini-3-flash` or
   `gemini-3.1-flash-lite` — rather than another 2.5-line model, since 2.5 is both
   actively erroring right now and already has its own scheduled shutdown later this
   year regardless.
3. Make the model name configurable in one clearly identifiable place (a constant or
   settings value), not buried inline in call logic — Google has been retiring model
   names on a roughly quarterly cadence this year, so the next swap should be a
   one-line change, not a repeat of this investigation.
4. Verify by actually sending a notebook-summary request and a chat-panel message
   end-to-end and confirming both succeed against the new model.

## Non-goals

- No other changes from Session 26 (rate-limit trigger bug, chat deletion, etc.) —
  those are considered separately handled
- No changes to the Anthropic/Claude side of the app
- No speculative handling for future deprecations beyond making the model name easy to
  change in one place

## Deliverable

`GeminiClient` calls a current, working 3.x-line model instead of the 404'ing
`gemini-2.5-flash`. The model name lives in one easily-editable location. Both a
notebook summary generation and a chat panel message succeed against the new model.
Tell me exactly which model you set it to and where the constant/setting lives.
