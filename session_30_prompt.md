# Session 30: Formatted + Collapsible Notebook Summary

## Agent Orchestration
If this session's usage crosses ~85% of budget before all tasks below are complete,
stop assigning further implementation work to Sonnet subagents. Instead, orchestrate
the remaining unfinished tasks using the local `codex` CLI (already installed on this
machine) as the implementing agent — hand off clearly scoped task descriptions to it
rather than continuing to consume Sonnet context. Finish the task currently in progress
before handing off, so nothing is left half-written with no assigned agent.

## Context

Continuing "Paper Reader." Sessions 23 and 29 built proper formatting rendering
(bold/italic/inline code/links, headers, and LaTeX equations) for the AI chat panel's
messages. The notebook AI summary (Session 10, content source changed in Session 29)
is displayed elsewhere in the app — likely as plain text in a notebook header/detail
view — and currently shows the same kind of raw, unrendered syntax the chat panel used
to (`**a**` instead of bold, `###` instead of a header, raw LaTeX instead of typeset
equations).

## Goal for this session

- Apply the **same formatting rendering pipeline** built for chat messages (Session 23
  for bold/italic/inline code/links, Session 29 for headers and LaTeX) to wherever the
  notebook summary text is displayed. Reuse that existing rendering component/function
  directly — don't write a second, parallel formatting renderer for the summary view.
  If the summary is currently rendered in a plain `Text`/label view that can't host the
  richer rendering, swap it for whatever view type the chat panel uses to display its
  messages (or a shared component extracted from it) so both places render identically.
- Verify by looking at a notebook whose summary (regenerated per Session 29's
  paper-content-based trigger) includes at least one bolded term, one header, and one
  equation if the source papers reasonably produce one — confirm all three render
  correctly rather than showing raw syntax.
- If the summary is shown in more than one place in the app (e.g. both a compact
  All-Folders card preview and a full notebook detail view), confirm both use the
  shared rendering rather than only fixing the first place you find it.
- **Make the summary collapsible.** Wherever the full-length summary is displayed
  (likely the notebook detail view — a compact All-Folders card preview, if one
  exists, can stay as a short excerpt regardless), add a collapse/expand control:
  - Collapsed state shows a short preview (e.g. first line or first N characters,
    with a "Show more" affordance) rather than the full summary text.
  - Expanded state shows the full formatted summary.
  - Default to collapsed, since a several-paragraph AI summary shouldn't dominate the
    notebook view by default — flag if you think expanded-by-default reads better in
    practice and why.
  - Persist the collapsed/expanded state per notebook (so re-opening a notebook you'd
    previously expanded doesn't collapse it again), unless that's meaningfully more
    work than it's worth — flag which you did.

## Non-goals

- No changes to what triggers summary regeneration or what content is summarized —
  that's Session 29's concern, this session is purely about how the existing summary
  text is displayed
- No new formatting capabilities beyond what Sessions 23/29 already built — this is a
  reuse task, not a new rendering feature

## Deliverable

App builds and runs. Wherever the notebook AI summary is displayed, bold/italic text,
headers, and LaTeX equations all render properly instead of showing raw markdown/LaTeX
syntax, using the same rendering logic already built for the chat panel. The summary
is collapsible — collapsed by default to a short preview, expandable to the full
formatted text. Flag whether the summary is shown in more than one place and confirm
all of them were updated, and note whether collapsed/expanded state persists per
notebook or resets each time.
