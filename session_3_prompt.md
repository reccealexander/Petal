# Session 3: Highlighting + Comment Popover

## Context

Continuing "Paper Reader." Session 1 built the DB layer (GRDB, schema, migrations).
Session 2 built PDF import, a `PDFImportService`, and a working `PDFReaderView` /
`PDFKitWrapper` that renders imported papers. This session adds the core annotation
loop: select text, highlight it, attach a comment to it.

Full project spec is attached (paper_reader_spec.md) — refer to §1 for the `Highlight`
and `Comment` schema (already created in Session 1's migration, no new tables needed),
§3 Phase 1 for scope, and §5 for the note on PDFKit annotations vs. DB as source of
truth — that note matters a lot for this session specifically.

## Goal for this session

1. **Text selection → highlight:**
   - Detect the user's current selection in `PDFKitWrapper` (`PDFView.currentSelection`)
   - Add a toolbar (or contextual menu on the selection) with 3–4 highlight colors
   - On color pick: convert the `PDFSelection` into per-page bounding boxes (a
     selection can span multiple lines/pages — store one row per contiguous span,
     or a JSON array of rects if it's a single highlight spanning multiple boxes,
     matching the `bounding_boxes` JSON column from the schema)
   - Create a `PDFAnnotation(subtype: .highlight, ...)` on the actual `PDFPage` so it
     renders visually inline (this is the "also visible in Preview.app" behavior
     from spec §5)
   - **In the same operation**, persist a `Highlight` row via GRDB with the selected
     text, page, bounding boxes, and color — DB is the source of truth; the PDFKit
     annotation is a rendering of it, not an independent copy
2. **Comment popover:**
   - Clicking an existing highlight (not creating a new one) opens an `NSPopover`
     anchored to the highlight's on-screen rect
   - Simple markdown text field inside — save/cancel
   - Persist as a `Comment` row linked to that `highlight_id`
   - If a highlight already has a comment, clicking it should open the popover
     pre-filled with the existing comment for editing, not create a second one
3. **Rehydration on open:** when a paper is opened, load all its `Highlight` rows from
   the DB and re-render them as `PDFAnnotation`s on the correct pages — don't rely on
   annotations persisted in the PDF file itself surviving; rebuild from DB every time,
   per spec §5 ("if DB and PDF annotations ever diverge, DB wins").
4. **Visual indicator for commented highlights:** something simple — e.g. a small dot
   or different border — so it's visually obvious which highlights have a comment
   attached vs. which are "just a highlight."

## Explicit non-goals for this session

- No detached notes window (Session 4)
- No notebook/folder nesting or tags (Session 5)
- No search (Session 5)
- No Claude panel (Session 6+)
- No highlight editing beyond color + comment (no resizing/moving an existing highlight)
- No deleting highlights yet is fine to skip, but if it's trivial to add (right-click →
  delete), include it — your call

## Constraints / preferences

- Highlight color categories should be a simple enum (e.g. `.yellow, .green, .blue, .pink`)
  matching the `color` column default from the schema — don't invent a different scheme.
- Keep the PDFKit-annotation-rendering logic and the DB-persistence logic in clearly
  separate functions/files (e.g. `HighlightRenderer` vs. `HighlightRepository`) so a
  later session can swap one without touching the other.
- Reuse `PDFKitWrapper` from Session 2 — extend it, don't fork a second PDF view.

## Deliverable

App builds and runs. I should be able to: open a paper, select text, pick a color, see
it highlighted inline, click the highlight, type a comment, close and reopen the paper,
and see both the highlight and the comment still there exactly as I left them. Show me
the final file tree and flag any judgment calls — especially anything about how you
handled a highlight that spans a page break, since that's the trickiest edge case here.
