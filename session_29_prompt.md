# Session 29: LaTeX + Markdown Rendering, Card/Thumbnail Keyboard Nav, Chapter Sidebar

## Agent Orchestration
If this session's usage crosses ~85% of budget before all tasks below are complete,
stop assigning further implementation work to Sonnet subagents. Instead, orchestrate
the remaining unfinished tasks using the local `codex` CLI (already installed on this
machine) as the implementing agent — hand off clearly scoped task descriptions to it
rather than continuing to consume Sonnet context. Finish the task currently in progress
before handing off, so nothing is left half-written with no assigned agent.

## Context

Continuing "Paper Reader." Four independent items: fixing remaining chat-response
formatting gaps (LaTeX and headers), arrow-key navigation for library cards, arrow-key
navigation within the thumbnail sidebar, and a new chapter/outline sidebar view with a
keyboard shortcut to jump between chapters.

## 1. Render LaTeX and remaining markdown formatting in chat responses

Session 23 got inline markdown (bold/italic/inline code/links) rendering correctly via
`AttributedString(markdown:)`, but flagged block-level constructs as incomplete. Two
concrete gaps to fix now:

- **Headers:** `###` (and `#`, `##`) are currently showing as literal characters
  instead of rendering as headers. Add explicit handling for markdown headers in the
  chat message rendering path — detect leading `#`/`##`/`###` at the start of a line
  and render with appropriately larger/bolder text, since `AttributedString(markdown:)`
  alone may not surface this the way you'd want for a chat bubble.
- **LaTeX equations:** the AI (Claude or Gemini, per Session 20's provider toggle)
  will often return math wrapped in standard LaTeX delimiters — `$...$` or `\(...\)`
  for inline math, `$$...$$` or `\[...\]` for display/block math. Detect these
  delimiters in the response text and render the enclosed LaTeX as actual typeset math
  rather than showing raw LaTeX source. Use a lightweight native rendering approach
  (e.g. `SwiftMath` via Swift Package Manager) rather than embedding a full WKWebView
  + KaTeX just for this — reserve the heavier web-based approach only if a native
  library proves insufficient for the equation complexity you actually encounter.
  Given this is a physics-research tool, prioritize getting common constructs right:
  fractions, subscripts/superscripts, Greek letters, summations/integrals, and basic
  matrix notation.
- Verify by asking the chatbot a question that naturally produces both a heading and
  an equation (e.g. "explain the structure of this derivation with section headers"),
  and confirming both render correctly rather than showing raw syntax.

## 2. Up/down arrow navigation for library cards (All Papers)

- Session 16 added arrow-key navigation across view modes, but confirm/extend this
  specifically for the **All Papers** view: **up/down arrows** move the selection to
  the adjacent card (row above/below in Grid, or previous/next row in List), regardless
  of which view mode is active there. If Session 16's implementation already covers
  this correctly for All Papers, this task may just be verification — if it doesn't
  (e.g. it only wired up left/right, or doesn't cover the All Papers context
  specifically), fix it so up/down works there.
- Enter/Return on the selected card still opens it, consistent with Session 16.

## 3. Down arrow navigation within the thumbnail sidebar

Distinct from Task 2 (which is about library cards) — this is about the **page
thumbnail sidebar inside the PDF reader** (Session 6). When a thumbnail is selected
(clicked/focused) in that sidebar, pressing the **down arrow** should move the
selection to the next page's thumbnail and jump the main reader view to that page
(mirroring clicking the next thumbnail directly). Confirm up arrow moves to the
previous page's thumbnail for symmetry, even though only down was explicitly
requested.

## 4. Chapter/outline sidebar view + ⌘→ to jump between chapters

- Add a new sidebar mode inside the PDF reader (alongside the existing page-thumbnail
  sidebar from Session 6) that shows the paper's **chapter/section outline** instead
  of page thumbnails. Use `PDFDocument.outlineRoot` (PDFKit's built-in outline/bookmark
  API) to read whatever table-of-contents structure is embedded in the PDF itself —
  most properly-formatted paper PDFs (especially from publishers) include this.
  Provide a toggle to switch the sidebar between "Thumbnails" and "Chapters" modes.
- **Handle PDFs with no embedded outline gracefully** — many arXiv preprints and
  scanned papers won't have one. If `outlineRoot` is nil or empty, show a clear
  "no chapter data available for this paper" state in Chapters mode rather than an
  empty/broken-looking view.
- **⌘→ (Command + Right Arrow)** jumps to the next chapter/section (using the
  outline's flat or hierarchical entry order — top-level jumps are enough, doesn't
  need to walk into nested sub-sections for this session). Clicking a chapter entry in
  the sidebar should also jump directly to it, same as clicking a thumbnail does today.

## 5. Change notebook AI summary trigger: papers, not notes

Session 10 built notebook summaries (via Gemini) to regenerate when a new note is
added to the notebook, tracked via `ai_summary_note_count`. Change this: summaries
should **no longer be triggered by notes at all**. Instead, the summary should be
generated by reading the actual PDFs (papers) in the notebook, and should regenerate
when the notebook's set of papers changes — a paper is added, removed, or moved into/
out of the notebook.

- **Schema:** add a column that lets you detect a paper-set change (e.g.
  `ai_summary_paper_count INTEGER DEFAULT 0` plus a hash/snapshot of the paper IDs
  included in the last summary, or simply compare the current paper count and set
  against what was last summarized — pick whichever is simpler to implement reliably,
  flag your choice). Keep `ai_summary` itself as-is; you're changing what triggers
  regeneration and what content gets summarized, not where the result is stored.
- **Trigger:** check for regeneration when a paper is added to, removed from, or moved
  into/out of a notebook (reuse whatever notebook-membership-change events already
  exist from Session 12's drag-to-notebook functionality) — not on note creation or
  editing at all. Remove the old note-count-based trigger entirely rather than leaving
  it alongside the new one.
- **Content sent to Gemini:** instead of notes content, extract and send the actual
  PDF text (or a reasonable portion of it — page 1/abstract plus headings, if sending
  full text for every paper in a large notebook would be excessive — your call, flag
  what you sent) for every paper currently in the notebook, so the summary reflects
  what the papers are actually about, not what's been written about them.
- Confirm by adding/removing a paper from a notebook and checking the summary
  regenerates; separately, confirm adding or editing a note in that same notebook does
  **not** trigger a Gemini call at all anymore.

## Non-goals

- No LaTeX rendering inside notes (Session 23's rich text editor) this session — this
  task is specifically for chat panel responses
- No manual chapter/outline editing for PDFs that lack one — detection and navigation
  only, not authoring
- No ⌘← (previous chapter) requirement, though it's a natural, low-cost addition if
  trivial alongside ⌘→ — flag if you added it

## Deliverable

App builds and runs. Chat responses render `#`/`##`/`###` headers and LaTeX equations
(inline and block) instead of showing raw syntax. Up/down arrows move selection
between library cards in All Papers, with Enter opening the selected one. In the
reader's thumbnail sidebar, selecting a thumbnail and pressing down arrow advances to
the next page. A new Chapters sidebar mode shows a PDF's embedded outline when
available, with a clear empty-state when it isn't, and ⌘→ jumps to the next chapter.
Notebook summaries now regenerate only when the notebook's papers change (not on note
activity), and are generated from the papers' actual PDF content. Flag which LaTeX
rendering approach you used and how well it handled real equation complexity from an
actual paper, and how you chose to detect a paper-set change for the summary trigger.
