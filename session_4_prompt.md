# Session 4: Detached Notes Window

## Context

Continuing "Paper Reader." Session 1 built the DB layer. Session 2 built PDF import and
the reader view. Session 3 added highlighting and comment popovers linked to specific
selections. This session adds the other kind of note-taking described in the original
spec: a **detached notes window** per paper — a running scratchpad for synthesis,
separate from inline highlight comments, that can be open side-by-side with the PDF.

Full project spec is attached (paper_reader_spec.md) — refer to §1 for the `Note` schema
(already created in Session 1's migration, no new tables needed) and §3 Phase 1 for
scope. Note the schema already supports `note.paper_id` OR `note.notebook_id` (nullable
each) — this session only deals with paper-scoped notes; notebook-scoped notes come
later alongside notebooks in Session 5.

## Goal for this session

1. **Opening the notes window:**
   - A toolbar button in `PDFReaderView` ("Notes" or a notebook icon) opens a separate
     `NSWindow` (not a sheet/popover — this needs to be able to sit side-by-side with
     the reader window, per the original spec)
   - One notes window per paper. If the user already has that paper's notes window
     open and clicks the button again, bring the existing window to front rather than
     opening a duplicate.
   - Window title should reflect the paper title, so it's identifiable in the Window
     menu / Mission Control when several are open at once.
2. **Editor:**
   - A simple markdown text editor — plain `TextEditor` wrapped with basic markdown
     rendering is fine for now (live WYSIWYG isn't required; a raw markdown pane, or a
     split raw/preview, both acceptable — your call, note which you chose)
   - Autosave on a short debounce (e.g. 1–2s after typing stops) rather than requiring
     an explicit save action — this should feel like a scratchpad, not a document you
     have to remember to save
3. **Persistence:**
   - A paper can have more than one note (the schema doesn't restrict to one), but for
     this session it's fine to default to "one primary note per paper" — create it
     lazily on first open if it doesn't exist, load it if it does
   - Store title (can default to something like "Notes — {paper title}" or be left
     blank) and body per the `Note` schema
4. **Linking highlights into notes:**
   - From Session 3's highlighted text, provide some lightweight way to reference a
     highlight from within a note — e.g. a "insert reference" action that drops a
     short markdown link/snippet into the notes editor at the cursor (e.g.
     `[p.3: "the exact selected text..."]`), and store that highlight's id in the
     note's `linked_highlight_ids` JSON array
   - Clicking such a reference in the notes editor should bring the reader window to
     that highlight's page (doesn't need to scroll to the exact rect yet, page-level
     is fine)

## Explicit non-goals for this session

- No notebook-level notes (notes tied to a notebook rather than a single paper) —
  that's bundled with Session 5's notebook work
- No rich WYSIWYG markdown editor — plain text/markdown is fine
- No notebook/folder nesting, tags, or search (Session 5)
- No Claude panel (Session 6+)
- No multi-note management UI (list of all notes for a paper) — defer that until it's
  clear whether one-note-per-paper is actually a limitation in practice

## Constraints / preferences

- Keep the notes window's state (open/closed, which paper) out of the main app's
  navigation state — it's a separate `NSWindow`, so treat it as its own lightweight
  lifecycle rather than routing it through the same view model as the reader.
- Reuse the `Note` GRDB model and `DatabaseManager` from Session 1 as-is.
- Debounced autosave logic should live in a small dedicated helper (e.g.
  `AutosaveController` or similar), not inlined ad hoc in the view, since Session 6's
  Claude panel will likely want to read "current note content" too and a clean
  read path will make that easier.

## Deliverable

App builds and runs. I should be able to: open a paper, open its notes window
alongside the reader, type notes and have them autosave, insert a reference to a
highlighted passage, close everything, reopen the paper, and see the note content and
the highlight reference both intact. Show me the final file tree and flag any judgment
calls — particularly which editor approach (plain markdown vs. split raw/preview) you
went with and why.
