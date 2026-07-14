# Session 33: AI-Assisted Note-Taking — Per-Page Key-Idea Highlight Suggestions

## Agent Orchestration
If this session's usage crosses ~85% of budget before all tasks below are complete,
stop assigning further implementation work to Sonnet subagents. Instead, orchestrate
the remaining unfinished tasks using the local `codex` CLI (already installed on this
machine) as the implementing agent — hand off clearly scoped task descriptions to it
rather than continuing to consume Sonnet context. Finish the task currently in progress
before handing off, so nothing is left half-written with no assigned agent.

## Context

Continuing "Paper Reader." The reader already supports manual, selection-driven
highlights: a text selection becomes one `highlight` row per page (JSON bounding boxes
in page space, a `color`, and the selected text), re-rendered onto the PDFKit page from
the database (`Views/Reader/PDFReaderView.swift`, `PDFKitWrapper.swift`,
`HighlightRenderer.swift`, `Services/HighlightRepository.swift`). Separately, the app
already has a Gemini-backed structured-suggestion pattern for tags
(`Services/TagSuggestionService.swift`, driven from the reader by
`ReaderTagPopoverModel.swift`), and provider-neutral AI routing via
`AIProviderPreference.effectiveProvider` (`Services/AIProvider.swift`).

This session adds an **AI-assisted note-taking mode**. When enabled, the AI reads the
**current PDF page's** text and suggests the sentences that capture that page's "key
ideas," surfacing them as **proposed highlights** the user can accept or dismiss. To
stay within the free Gemini tier's context limits, suggestions are computed **one page
at a time**, and the mode is driven **per page** — the user toggles AI-assisted mode for
whichever page they're on, rather than running it across the whole document at once.

Mirror the existing `TagSuggestionService` shape: a plain, SwiftUI-free,
unit-testable service in `PaperReaderCore` that does the Gemini call over `Sendable`
`String` values, driven by a reader-side view-model in `PaperReaderApp`. Reuse
`KeychainService.hasAPIKey`, `GeminiClient.streamMessage`, and the
`GeminiClientError.missingAPIKey` gate. Keep the Gemini model constant in its single
existing place. Tag suggestion is the established Gemini-only exception; this feature
may follow the same Gemini-only path (it depends on the free Gemini tier), but prefer
routing through `effectiveProvider` if it's a clean fit — pick one and say which.

## 1. Key-idea suggestion service (Core)

Add a plain service in `PaperReaderCore/Services` (e.g. `KeyIdeaSuggestionService`)
that, given a single page's plain text, asks the AI to return the **verbatim
sentences** from that page that are its key ideas (a small, bounded list — aim ~1–5 per
page, fewer on sparse pages, none if the page is figures/references/boilerplate). Follow
`TagSuggestionService`'s structure exactly:

- A synchronous, pure context/prompt-assembly step, then an `async` network call that
  only ever crosses isolation domains with plain `String`s (Swift 6 strict concurrency
  — do not hand a non-`Sendable` `Paper`/`PDFPage` into the `async` call).
- Gate on `hasAPIKey`; throw `GeminiClientError.missingAPIKey` without a network call
  when no key is configured.
- The returned strings must be **verbatim substrings of the page text** so they can be
  located on the page in Task 2. Instruct the model to copy sentences exactly (no
  paraphrasing, no added quotation marks/numbering), and parse the response
  defensively (the model may still wrap or number them). Put the prompt template in
  `QuickActionPrompts.swift` per the centralization convention.
- Keep the per-page text bounded (cap characters like `TagSuggestionService` does) so a
  dense page still fits the free tier.

Add focused Core unit tests for the parser (numbered/bulleted/quoted variants → clean
verbatim strings) the same way tag parsing is covered.

## 2. Locate suggested sentences on the page as highlight geometry (Core or App)

Given a suggested verbatim sentence and the target `PDFPage`, resolve it to bounding
box(es) in the **same page-coordinate space already stored in `highlight.bounding_boxes`**
(match `HighlightRenderer`/`HighlightRepository`'s existing convention exactly — do not
invent a new coordinate space). Use PDFKit (`PDFDocument.findString` / `PDFSelection` /
`selection.bounds(for:)` / `characterBounds`) to find the sentence's range on that page
and derive its rect(s).

- Be robust to whitespace/newline differences between the model's copy and the PDF's
  extracted text (normalize spacing when matching). If a suggestion can't be located on
  the page, **drop it silently** rather than creating a zero-rect highlight.
- The output of this step is a set of candidate highlights (page index, bounding boxes,
  selected text) — not yet persisted.

## 3. Per-page AI-assisted mode toggle + suggestion review UI (App)

In the reader, add a way to turn **AI-assisted note-taking mode** on/off, and, while
it's on, to run key-idea suggestion **for the current page**:

- A clear toggle in the reader chrome/toolbar (respect Focus Mode's floating toolbar
  too). Only offer it when a Gemini key exists (mirror how the tag popover checks
  `hasAPIKey`); otherwise guide the user to Settings as the existing AI surfaces do.
- Running suggestion on the current page shows the located suggestions as **pending
  highlights rendered in a visually distinct style** (e.g. a dedicated suggestion color
  / dashed outline) so they're obviously proposals, not committed highlights. Show a
  lightweight progress/empty/error state (page had no key ideas; no key configured;
  network error) consistent with the app's other AI surfaces.
- The user can **accept** a suggestion (individually, and ideally "accept all on this
  page") — accepted suggestions are persisted as **ordinary `highlight` rows** via
  `HighlightRepository` (reuse the exact existing insert + render path a manual
  highlight uses; note highlights are **not** in `search_index`, so no FTS write is
  needed) — and **dismiss** a suggestion, which just discards the proposal.
- Pending (unaccepted) suggestions are **ephemeral view state**, scoped per page. Moving
  away and back may re-run or clear them; they must never leak into the database until
  accepted. Toggling the mode off clears any pending suggestions for the page.

## Non-goals

- **No whole-document batch processing.** Suggestion is deliberately page-scoped and
  per-page-triggered to fit the free Gemini tier — do not add a "suggest for all pages"
  sweep.
- **No schema change / new migration.** Proposals are ephemeral until accepted, and
  accepted ones are ordinary highlights, so V1–V9 stand. Do not add a migration or a
  "suggested" flag column.
- **No auto-accept.** Suggestions always require explicit user confirmation; the AI
  never writes a highlight on its own.
- **No changes to the manual selection→highlight flow, the comment popover, or tag
  suggestion** beyond reusing their components/patterns.
- No new provider plumbing beyond the existing `effectiveProvider` / Gemini-only choice
  made in Task 1.

## Deliverable

App builds (Swift 6, macOS 14+) and runs; Core tests pass. With a Gemini key
configured, turning on AI-assisted note-taking mode and running it on the current page
surfaces that page's key sentences as visually-distinct pending highlights; accepting
one persists it as a normal highlight (surviving reopen), and dismissing discards it.
The whole flow is page-by-page, never batches the document, and adds no migration.
Flag any edge cases you found tricky — especially sentence-to-geometry matching failures
(hyphenation, ligatures, multi-column text, sentences spanning line/column breaks) and
how you handled unlocatable suggestions.
