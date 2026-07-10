# Session 10: Small Fixes + Notebook AI Summary (Gemini)

## Agent Orchestration
If this session's usage crosses ~85% of budget before all tasks below are complete,
stop assigning further implementation work to Sonnet subagents. Instead, orchestrate
the remaining unfinished tasks using the local `codex` CLI (already installed on this
machine) as the implementing agent — hand off clearly scoped task descriptions to it
rather than continuing to consume Sonnet context. Finish the task currently in progress
before handing off, so nothing is left half-written with no assigned agent.

## Context

Continuing "Paper Reader." Sessions 1–9 built the DB layer, reader, annotations, notes,
notebooks/tags/search, the app icon/launch screen, the Claude panel, and PDF-to-PDF
window snapping. This session is three small-to-medium, unrelated fixes.

## 1. Deleting a note closes its window

Session 8 added note deletion from both the notes window and the paper-side entry
point. Right now the DB row is removed but the notes `NSWindow` (if open) stays open,
showing a note that no longer exists. Fix: deleting a note should close its associated
notes window as part of the same action, from either entry point.

## 2. Launch screen: "Research Now" gate + icon quality

Currently the launch screen (Session 8) auto-dismisses into the main window after a
short delay. Change this: the launch screen should stay up indefinitely, showing the
icon on white plus a single button labeled **"Research Now."** Clicking it opens the
main window and closes the launch screen — no auto-timer.

Also: re-check the icon rendering on the launch screen. Session 9 swapped in
`EasyReader_icon.png` for quality, but if it still looks low-res, check whether the
launch screen is rendering a downscaled/cached thumbnail version of the icon rather
than the actual full-resolution asset — pull directly from the high-res source image,
not from any icon-cache path used elsewhere in the app.

## 3. AI-generated notebook summaries (Gemini API)

1. **Schema:** new migration adding `ai_summary TEXT` and `ai_summary_note_count
   INTEGER DEFAULT 0` to the `notebook` table. `ai_summary_note_count` tracks how many
   notes existed (across all papers in that notebook) the last time a summary was
   generated.
2. **API key:** settings field for a Gemini API key, stored via `KeychainService`
   using the same pattern as the existing Anthropic key (separate Keychain entry, not
   reused/overwritten).
3. **`GeminiClient`:** a new service wrapping calls to the Gemini API, mirroring
   `ClaudeClient`'s structure (distinct file, handles missing key / network / rate
   limit errors explicitly).
4. **Trigger logic:** when a note is created (paper-scoped, within a paper that
   belongs to a notebook), check if that notebook's current total note count exceeds
   `ai_summary_note_count`. If so, regenerate: send the notebook's papers (titles,
   highlights/comments) and all its notes' content to Gemini, store the result in
   `ai_summary`, and update `ai_summary_note_count` to the new total. **Do not**
   regenerate on comment/highlight-only changes, tag changes, or on every app open —
   only on a net-new note.
5. **Display:** show the cached `ai_summary` wherever the notebook is presented (e.g.
   notebook header/detail view). If it's `NULL` (never generated — e.g. an empty
   notebook), show an empty/placeholder state rather than an error.

## Non-goals

- No manual "regenerate summary" button this session (fine to add if trivial, flag if
  you do)
- No summary for individual papers, notebooks only
- No changes to the Claude panel or Anthropic integration

## Deliverable

App builds and runs. Deleting a note closes its window from both entry points. Launch
screen shows icon + "Research Now" button with no auto-dismiss, and the icon looks
sharp. Adding a note to a paper inside a notebook triggers (or doesn't, correctly)
notebook summary regeneration via Gemini, with the result cached and reused until the
next new note. Flag any judgment calls, especially on what exactly gets sent to Gemini
for summarization.
