# Session 2: PDF Import + PDFKit Viewer

## Context

Continuing "Paper Reader," a native macOS app (SwiftUI + AppKit/PDFKit) for reading and
annotating scientific papers. Session 1 built the project skeleton and the full GRDB
database layer (schema, migrations, record structs, `DatabaseManager`) — that's already
in place and tested. This session adds PDF import and a working PDF viewer. No
highlighting, no comments, no Claude panel yet — just get a PDF onto the screen and a
`Paper` row correctly persisted.

Full project spec is attached (paper_reader_spec.md) — refer to §2 (App Structure) for
file/folder layout and §3 Phase 1 for scope, and reuse the `Paper` model and
`DatabaseManager` from Session 1 rather than recreating them.

## Goal for this session

1. **Import flow:** a button (or drag-and-drop target) on the home placeholder screen
   that opens an `NSOpenPanel` filtered to `.pdf`, or accepts a dropped file.
2. **`PDFImportService`:**
   - Copy the selected PDF into `~/Library/Application Support/PaperReader/Papers/<paperId>.pdf`
     (generate the `paperId` as a UUID string client-side, per Session 1's ID convention)
   - Extract page count via `PDFDocument(url:)`
   - Extract a best-effort title: try PDF metadata (`PDFDocument.documentAttributes[.titleAttribute]`)
     first, fall back to the filename (without extension) if metadata is empty or missing
   - Generate a thumbnail image from page 1 (`PDFPage.thumbnail(of:for:)`) and cache it to
     disk alongside the PDF (e.g. `<paperId>_thumb.png`) rather than regenerating on every
     home-screen render
   - Insert a `Paper` row via the Session 1 GRDB models — no schema changes needed
   - Basic dedupe: hash the source file (SHA-256 is fine) before copying, check if a
     `Paper` with that hash already exists, and if so surface a "this paper is already
     imported" state instead of creating a duplicate. (This means adding a `file_hash`
     column to the `paper` table — do this as a new GRDB migration, not by editing
     Session 1's migration.)
3. **`PDFReaderView` + `PDFKitWrapper`:**
   - `NSViewRepresentable` wrapping `PDFView`
   - Configure for continuous scrolling, auto-scale to fit width
   - Open by loading the paper's copied file from disk (not the original import path)
   - Update `paper.last_opened_at` on open
4. **Home screen (still flat, no folders yet — that's Session 5 per the spec):**
   - Replace the Session 1 placeholder with a simple grid of `PaperCardView`s: thumbnail,
     title, page count
   - Clicking a card opens `PDFReaderView` for that paper (new window or navigation —
     your call on which feels more natural in SwiftUI/AppKit here, just be consistent)

## Explicit non-goals for this session

- No highlighting or annotation (Session 3)
- No comment popovers (Session 3)
- No notes window (Session 4)
- No notebook/folder nesting or tags (Session 5)
- No Claude API or panel (Session 6+)
- No search

## Constraints / preferences

- Reuse Session 1's `DatabaseManager` and GRDB models as-is; don't refactor them unless
  something is actually broken.
- New migration for `file_hash`, following the same `DatabaseMigrator` pattern
  established in Session 1 (additive, versioned, don't touch the existing migration file).
- Keep `PDFImportService` and `PDFKitWrapper` as separate, testable units — no PDF logic
  directly inside SwiftUI views.
- Thumbnail generation should happen once at import time, not on every app launch or
  every home-screen scroll.

## Deliverable

App builds and runs. I should be able to: click import, pick a PDF, see it appear as a
card on the home screen with a real thumbnail and title, click the card, and see the PDF
render correctly in a viewer window. Re-importing the same file should be caught by the
dedupe check rather than creating a second entry. Show me the final file tree and flag
any judgment calls (e.g. how you chose to open the reader — new window vs. in-place
navigation).
