# Session 23: Rich Text Notes, Resizable AI Panel, Markdown Rendering Fix

## Agent Orchestration
If this session's usage crosses ~85% of budget before all tasks below are complete,
stop assigning further implementation work to Sonnet subagents. Instead, orchestrate
the remaining unfinished tasks using the local `codex` CLI (already installed on this
machine) as the implementing agent — hand off clearly scoped task descriptions to it
rather than continuing to consume Sonnet context. Finish the task currently in progress
before handing off, so nothing is left half-written with no assigned agent.

## Context

Continuing "Paper Reader." Three pieces this session: upgrading the plain-markdown
notes editor (Session 4) to a real rich-text editor, making the AI chat panel
(Session 6) user-resizable, and fixing the chat panel so it actually renders markdown
formatting instead of showing raw syntax characters.

## 1. Rich text notes editor (Google-Docs-like)

This is the biggest task this session and involves a real data-model change — read
this whole section before starting.

- **Editor:** replace the plain `TextEditor` from Session 4 with a proper rich-text
  editor backed by `NSTextView` (TextKit), with a toolbar offering at minimum: font
  family picker, font size, bold/italic/underline, text color, bullet list, numbered
  list, and basic alignment (left/center/right). This is a meaningfully bigger
  component than Session 4's plain editor — treat it as its own view/controller
  (`RichTextEditorView` or similar), not a small patch to the existing one.
- **Storage change:** markdown text can't represent arbitrary font/size choices, so
  switch note storage to real rich text:
  - Add a new column `note.body_rtf BLOB` (or base64-encoded `TEXT`, your call) that
    stores the note as RTF/RTFD data (`NSAttributedString`'s native archive format).
  - Keep `note.body` as a **plain-text-only extraction** of the same content,
    auto-derived whenever the rich content changes — this is what Session 5's
    `search_index` FTS5 table indexes, so full-text search must keep working
    unchanged from the user's perspective.
  - Migration: for existing notes (currently plain markdown text in `note.body`),
    write a migration that wraps that existing plain text into a minimal valid
    RTF representation for `body_rtf`, so old notes still open and display correctly
    rather than appearing blank.
- **Highlight references:** Session 4's "insert reference to a highlight" feature
  (`linked_highlight_ids`, clickable jump-to-page) must keep working inside the new
  rich editor — treat inserted references as their own styled inline element (e.g. a
  distinctly-colored, non-editable-text chip or link-styled span) rather than plain
  text that could accidentally be reformatted/mangled by the user.
- **Autosave:** keep the same debounced autosave pattern from Session 4, now writing
  both `body_rtf` and the derived `body` plain-text on each debounced save.

## 2. Resizable AI chat panel

- The Claude/AI panel (Session 6, third pane in the `NSSplitViewController`) should be
  resizable by dragging its divider, with reasonable min/max width constraints (don't
  let it be dragged down to unusably narrow, or expand to swallow the entire window).
- If the split view's divider is already technically draggable but something is
  preventing it in practice (fixed pane width constraint, `holdingPriority` set too
  high, etc.), find and remove whatever's blocking it rather than adding a second,
  separate resize mechanism.
- Persist the user's chosen panel width across app relaunches (a simple stored
  preference is fine) rather than resetting to a default every time.

## 3. Fix: chat responses should render markdown formatting, not show raw syntax

Right now the AI panel's chat messages likely show literal characters like `**a**`
instead of rendering **a** in bold. Fix the message-rendering path so common markdown
is actually rendered:
- Bold (`**text**`), italic (`*text*` or `_text_`), inline code (`` `code` ``), and
  links at minimum.
- Use Swift's built-in `AttributedString(markdown:)` initializer (available in modern
  Foundation) as the primary approach for inline formatting — it's the simplest robust
  option and avoids hand-rolling a markdown parser. Note its known limitation: it
  handles inline styling well but has weaker support for block-level constructs (lists,
  code blocks, headers) — if the AI's responses commonly include bulleted lists or
  multi-line code blocks, you may need a small amount of pre-processing (e.g. detect
  fenced code blocks and render them in a monospaced block manually) on top of the
  built-in initializer rather than relying on it alone. Flag exactly which markdown
  constructs you got rendering correctly and which (if any) still show raw syntax.

## Non-goals

- No collaborative/multi-user editing (Google Docs' real-time collaboration) — this
  is about rich text *formatting* capability, not collaboration features
- No embedded images/tables in notes this session
- No changes to notebook-scope note handling beyond what's needed for the storage
  format change

## Constraints

- Keep the rich-text storage change isolated to `Note`-related files
  (`Note` model, `NotesWindow`, the new `RichTextEditorView`) — don't touch
  `Highlight`/`Comment` storage, which stay plain markdown text as before.
- Confirm the FTS5 search from Session 5 still returns correct results for notes after
  this change — test by searching for a phrase inside a note's body after editing it
  in the new rich editor.

## Deliverable

App builds and runs. Notes support font family/size, bold/italic/underline, text
color, and bulleted/numbered lists, with old plain-text notes still opening correctly
after migration. The AI chat panel can be resized by dragging its divider and
remembers its width across relaunches. Chat responses render bold/italic/inline code/
links instead of showing raw markdown characters. Flag which markdown constructs
(especially lists and code blocks) ended up fully working versus needing more work
later, and confirm search still finds text inside rich notes correctly.
