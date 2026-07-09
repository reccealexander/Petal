# Session 1: Project Scaffold + Database Layer

## Context

I'm building "Paper Reader," a native macOS app (SwiftUI + AppKit/PDFKit) for reading and
annotating scientific papers, with an integrated Claude side panel for Q&A. This is the
first of several sessions — this one only covers the project skeleton and the database
layer. No PDF rendering, no UI beyond a placeholder window, yet.

Full project spec is attached (paper_reader_spec.md) — refer to §1 (Data Model) and §2
(App Structure) as the source of truth for schema and folder layout.

## Goal for this session

1. Create a new macOS SwiftUI app project named `PaperReader`, targeting macOS 14+.
2. Add GRDB.swift as a dependency (Swift Package Manager).
3. Implement the full database schema from §1 of the spec, using GRDB migrations
   (not raw SQL run ad hoc — use `DatabaseMigrator` so schema changes are versioned
   from day one).
4. Create GRDB record structs (conforming to `Codable`, `FetchableRecord`,
   `PersistableRecord`) for each table: `Notebook`, `Paper`, `Tag`, `PaperTag`,
   `Highlight`, `Comment`, `Note`, `ChatSession`.
5. Set up `DatabaseManager` (singleton or injected dependency) that:
   - Creates/opens the DB at `~/Library/Application Support/PaperReader/db.sqlite`
   - Creates the `Papers/` subdirectory alongside it for copied PDF files
   - Runs migrations on launch
   - Exposes a `DatabaseQueue` for the rest of the app to use
6. Write a handful of unit tests that:
   - Insert a nested notebook structure (parent + child) and verify the recursive
     query pattern from §1 works (fetch all papers under a notebook including
     subfolders)
   - Insert a paper, a highlight, and a comment linked to that highlight, and verify
     cascade delete works (deleting the paper removes its highlights and comments)
   - Insert rows into `search_index` (FTS5) and verify a basic full-text query
     returns the right entity
7. App should build and run, showing just a plain window (e.g. "PaperReader — DB
   initialized" placeholder text) — no need for real UI yet. Print or log confirmation
   that the DB was created/migrated successfully on launch, so I can verify visually.

## Explicit non-goals for this session

- No PDF import, rendering, or PDFKit usage yet (that's Session 2)
- No SwiftUI views beyond the placeholder window
- No Claude API integration
- No Keychain usage yet

## Constraints / preferences

- Use Swift Package Manager, not CocoaPods.
- Follow the file/folder structure in spec §2 (`Models/`, `Database/`, `Database/Migrations/`)
  so later sessions slot in cleanly.
- Use `TEXT` primary keys with UUID strings (matching the spec's schema) rather than
  autoincrementing integers, since IDs may need to be generated client-side before
  insert (e.g. when creating a highlight before it's persisted).
- Keep migration files one-per-logical-change (e.g. `v1_initial_schema.swift`) so future
  schema changes are additive, not edits to existing migrations.

## Deliverable

A working Xcode project that builds and runs, with the DB layer fully in place and
tested. Show me the final file tree when done, and flag anything in the spec that was
ambiguous or that you made a judgment call on.
