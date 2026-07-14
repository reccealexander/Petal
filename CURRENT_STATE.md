# PaperReader — Current State

> **Working-context warning:** `paper_reader_spec.md` and every individual `session_*_prompt.md` file are **historical record only**. Do **not** attach them as working context for new sessions. Use this file and `CLAUDE.md` as their current replacements; the code remains the source of truth.

## Database schema

SQLite/GRDB schema after migrations V1–V9. `?` means nullable; defaults do not imply `NOT NULL`. Entity IDs are UUID strings. Foreign keys are enabled.

| Table | Current columns and constraints |
|---|---|
| `notebook` | `id TEXT PK`; `name TEXT NOT NULL`; `parent_id TEXT? FK notebook(id) ON DELETE CASCADE`; `created_at DATETIME? DEFAULT CURRENT_TIMESTAMP`; `sort_order INTEGER? DEFAULT 0`; **V3:** `ai_summary TEXT?`, `ai_summary_note_count INTEGER? DEFAULT 0`; **V5:** `pinned_at DATETIME?` |
| `paper` | `id TEXT PK`; `notebook_id TEXT? FK notebook(id) ON DELETE SET NULL`; `title TEXT?`; `authors TEXT?`; `doi TEXT?`; `arxiv_id TEXT?`; `file_path TEXT NOT NULL` (relative to managed `Papers/`); `page_count INTEGER?`; `imported_at DATETIME? DEFAULT CURRENT_TIMESTAMP`; `last_opened_at DATETIME?`; **V2:** `file_hash TEXT?` (indexed); **V4:** `free_space_x DOUBLE?`, `free_space_y DOUBLE?`; **V5:** `pinned_at DATETIME?`; **V7:** `last_page INTEGER?`, `last_scroll_offset DOUBLE?`, `reading_status TEXT? DEFAULT 'unread'`; **V8:** `furthest_page_read INTEGER? DEFAULT 0` |
| `highlight` | `id TEXT PK`; `paper_id TEXT? FK paper(id) ON DELETE CASCADE`; `page INTEGER NOT NULL` (zero-based); `bounding_boxes TEXT NOT NULL` (JSON `[CGRect]`); `color TEXT? DEFAULT 'yellow'`; `selected_text TEXT NOT NULL`; `created_at DATETIME? DEFAULT CURRENT_TIMESTAMP` |
| `comment` | `id TEXT PK`; `highlight_id TEXT? FK highlight(id) ON DELETE CASCADE`; `paper_id TEXT? FK paper(id) ON DELETE CASCADE`; `body TEXT NOT NULL` (Markdown); `created_at DATETIME? DEFAULT CURRENT_TIMESTAMP`; `updated_at DATETIME?` |
| `note` | `id TEXT PK`; `paper_id TEXT? FK paper(id) ON DELETE CASCADE`; `notebook_id TEXT? FK notebook(id) ON DELETE CASCADE`; `title TEXT?`; `body TEXT NOT NULL` (plain-text search projection); `linked_highlight_ids TEXT?` (JSON IDs); `created_at DATETIME? DEFAULT CURRENT_TIMESTAMP`; `updated_at DATETIME?`; **V9:** `body_rtf BLOB?` (canonical rich text; existing rows backfilled) |
| `tag` | `id TEXT PK`; `name TEXT NOT NULL UNIQUE` |
| `paper_tag` | `paper_id TEXT NOT NULL FK paper(id) ON DELETE CASCADE`; `tag_id TEXT NOT NULL FK tag(id) ON DELETE CASCADE`; composite PK `(paper_id, tag_id)` |
| `chat_session` | `id TEXT PK`; `scope TEXT NOT NULL` (`paper` or `notebook`); `scope_id TEXT NOT NULL` (logical reference, no FK); `messages TEXT NOT NULL` (JSON messages); `created_at DATETIME? DEFAULT CURRENT_TIMESTAMP`; `updated_at DATETIME?` |
| `page_bookmark` | **V6:** `id TEXT PK`; `paper_id TEXT? FK paper(id) ON DELETE CASCADE`; `page INTEGER NOT NULL` (zero-based). The model treats `paper_id` as non-optional, but the migration does not declare `NOT NULL`; there is no `(paper_id, page)` uniqueness constraint. |
| `search_index` | FTS5 virtual table: untyped `entity_id`, `entity_type` (`paper`, `note`, `comment`), `paper_id`, `content`. Maintained explicitly by repositories/import/deletion paths, not by triggers or foreign keys. |

Migration registration order is fixed in `PaperReader/Database/DatabaseManager.swift`: `V1InitialSchema` → `V2AddFileHash` → `V3AddNotebookSummary` → `V4AddFreeSpacePosition` → `V5AddPinnedAt` → `V6AddPageBookmark` → `V7AddReadingProgress` → `V8AddFurthestPageRead` → `V9AddNoteRTF`.

## Project structure

```text
PaperReader/
├── App/                         app entry/state, appearance, focus, window joining
├── Database/                   DatabaseManager + Migrations/V1...V9
├── Models/                     GRDB records/value types
├── Resources/                  currently only .gitkeep
├── Services/                   repositories, import/search, AI clients/context
└── Views/
    ├── ClaudePanel/            scoped chat panel + view model
    ├── Home/                   library/sidebar/layouts/search/filter UI
    ├── Notes/                  library, detached editor, RTF/autosave
    ├── Reader/                 PDFKit reader, annotations, compare/join helpers
    └── Settings/               API keys, appearance, quick tips
Tests/PaperReaderCoreTests/     Core repository/service tests
scripts/                        app packaging and DMG scripts
packaging/                      packaging assets
Package.swift                   Swift 6 package, macOS 14+
```

- `PaperReaderCore` (library): `Models`, `Database`, `Services`; depends on GRDB; tests link this target.
- `PaperReaderApp` (executable): `App` and all `Views`; depends on `PaperReaderCore`.
- The repository currently contains 83 Swift files under `PaperReader/` and 10 test Swift files.

## Feature inventory

### Reading and annotation

- Managed PDF import, SHA-256 dedupe, metadata/page count, cover thumbnail, and paper FTS indexing — `Services/PDFImportService.swift`.
- PDFKit reader with 100% initial zoom, persisted page/offset resume, furthest-page progress, reading status, selection-driven highlights, and comment popovers — `Views/Reader/PDFReaderView.swift`, `PDFKitWrapper.swift`.
- Multi-page selections become one highlight row per page; JSON geometry is re-rendered from the DB — `Views/Reader/HighlightRenderer.swift`, `Services/HighlightRepository.swift`.
- Lazy memory/disk page thumbnails, synchronized navigation, and per-page bookmarks — `PageThumbnailProvider.swift`, `PageThumbnailSidebar.swift`, `PageBookmarkStore.swift`, `Services/PageBookmarkRepository.swift`.
- Paper/notebook highlight taxonomy and reader tag editing with AI suggestions — `HighlightTaxonomyView.swift`, `ReaderTagPopoverModel.swift`, `Services/TagSuggestionService.swift`.
- Per-page AI-assisted note-taking mode: while the "AI Notes" reader toggle is on, key-idea suggestions are generated **automatically for whichever page you scroll to** (500 ms-debounced, one fetch per page per document load, cached and redrawn on revisit). The AI's verbatim "key idea" sentences are located on the page and rendered as translucent-orange pending highlight annotations, revealed with a GPU Core Animation overlay (`SweepOverlayView`): each highlight sweeps in top-to-bottom, a red L-line draws from it up to a transient "Key Insight" tag in the upper-left margin, the tag wipes open right-to-left, then the tag and line vanish. The tag is purely an animation flourish — never a persistent annotation — so nothing lingers when AI Notes is toggled off. Clicking an orange highlight accepts it (it becomes a stored yellow highlight); the review popover offers Dismiss/Accept-all and a free-text field for what should count as a key insight. A "Review key ideas" popover offers Dismiss/Accept-all — `Services/KeyIdeaSuggestionService.swift`, `Views/Reader/KeyIdeaProposal.swift`, `HighlightRenderer.locate`, `PDFKitWrapper.swift`, `PDFReaderView.swift`.

### Notes

- Paper notes window: RTF `NSTextView`, formatting controls, clickable highlight references, 1.5-second debounced save/close flush — `Views/Notes/NotesView.swift`, `NotesViewModel.swift`, `RichTextEditorView.swift`, `AutosaveController.swift`.
- Library notes: create and plain-text-edit paper-linked, notebook-linked, or unlinked notes; filter and group by recent/notebook/tag/link status — `Views/Notes/NotesLibraryView.swift`.
- CRUD and same-transaction FTS maintenance — `Services/NoteRepository.swift`, `Services/SearchIndex.swift`.

### Organization

- Arbitrarily nested notebooks, recursive paper scope, cycle-safe moves, Unfiled, pinning, and `paper:`/`notebook:` drag/drop — `NotebookTreeView.swift`, `AllFoldersView.swift`, `Services/NotebookRepository.swift`. Sidebar drag also un-nests a subfolder to root and unfiles a paper via All Papers; a right-click "Move to…" hierarchical submenu on paper cards is a multi-select-aware, non-drag alternative — `NotebookTreeView.swift`, `PaperCardView.swift`, `PaperInteractionShell.swift`.
- Grid, list, and free-space pages with keyboard/card selection; Graph is a Free Space toggle connecting paper nodes that share tags — `PaperPagedLibraryView.swift`, `PaperGridView.swift`, `PaperListView.swift`, `FreeSpaceCanvasView.swift`, `PaperSelectionController.swift`. Inside a selected notebook, its direct subfolders render as reusable `AllFolderCard` stacked-thumbnail cards alongside the notebook's own (direct-only) papers; tapping one navigates in — `AllFoldersView.swift` (`AllFolderCard`), `LibraryViewModel.folderPreview`.
- AND-semantics tag filtering, reading-status filtering, flat/notebook/tag grouping, pin-first ordering, global paper/notebook search, and FTS result search — `HomeView.swift`, `LibraryViewModel.swift`, `TagFilterView`/`ReadingStatusFilterView` (declared in `HomeView.swift`), `GlobalSearchOverlay.swift`, `Services/SearchRepository.swift`.

### Window management

- Separate main, reader, notes, chat, compare, joined, and Settings scenes — `App/PaperReaderApp.swift`.
- Explicit two-paper compare plus split-out; reader panes scroll/zoom independently — `Views/Reader/CompareReaderView.swift`.
- Best-effort edge snap joins any registered main/reader/notes pair into an `HSplitView`, with split-out — `Views/Reader/CompareCoordinator.swift`, `App/WindowJoining.swift`.
- Focus Mode hides other apps and PaperReader windows, strips reader chrome, and exposes a floating reader toolbar — `App/FocusModeController.swift`, `Views/Reader/PDFReaderView.swift`.

### Claude/Gemini AI

- Streaming paper/notebook chat, scope switcher, quick actions, multiple persisted conversations, and resizable/detached panels — `Views/ClaudePanel/ClaudePanelView.swift`, `ClaudePanelViewModel.swift`, `Services/ChatSessionRepository.swift`, `QuickActionPrompts.swift`.
- Provider-agnostic effective routing for chat and notebook summaries; raw HTTPS clients for Anthropic and Google — `Services/AIProvider.swift`, `ClaudeClient.swift`, `GeminiClient.swift`.
- Fresh per-send context from PDF text plus highlights/comments/notes, with notebook full-text budgets — `Services/ContextBuilder.swift`.
- Count-guarded, actor-serialized cached notebook summaries — `Services/NotebookSummaryService.swift`.
- Gemini-only paper tag suggestions from metadata, PDF excerpts, highlights/comments, and notes — `Services/TagSuggestionService.swift`.
- Gemini-only, page-scoped key-idea sentence suggestions (verbatim substrings, parsed one-per-line, capped at 5) for AI-assisted note-taking — `Services/KeyIdeaSuggestionService.swift`, prompt in `QuickActionPrompts.swift`.

### Appearance and settings

- Live System/Light/Dark appearance, main-window transparency, progress visibility, AI-pane width, and chat font preferences — `App/AppearanceManager.swift`, `Views/Settings/SettingsView.swift`.
- System-accent observation plus shared pin/progress/status presentation — `Views/Home/AccentColorProvider.swift`.
- Per-provider Keychain API keys, preferred provider UI, and Quick Tips — `SettingsView.swift`, `Services/KeychainService.swift`, `QuickTipsView.swift`.

## Known quirks and non-obvious decisions

- Opening an `unread` paper changes it to `in_progress`. Reaching the final page for the first time in that reader coordinator auto-writes `read` when `furthest_page_read` reaches `page_count`. A later manual status write remains in force; a manual choice made before that first 100% crossing can still be auto-promoted (`PDFReaderView`, `PDFKitWrapper`, `NotebookRepository.setReadingStatus`).
- Focus Mode uses `NSRunningApplication.hide()`/`unhide()` for other regular apps and `orderOut`/`orderBack` for other PaperReader windows—no Accessibility API. Exit activates PaperReader and re-fronts the focused reader (`FocusModeController`).
- Shift-click selects **exactly two** papers: the last plain-click anchor and the clicked paper. It is intentionally not range selection; a second plain click on the sole selected paper opens it (`PaperSelectionController`).
- Chat context is opt-in UI state via `includeContext`, default `true`; typed sends honor the toggle, while quick actions always request context (`ClaudePanelViewModel`, `ClaudePanelView`). Context is rebuilt for every send.
- The detached editor treats `note.body_rtf` as canonical, derives `note.body` from `NSAttributedString.string`, and indexes the plain text. The inline Notes Library editor is an exception: `NoteEditorViewModel.saveNow` updates only `body`/`title`, leaving any existing `body_rtf` unchanged, so the two representations can diverge (`NotesViewModel`, `NotesLibraryView`, `SearchIndex.indexNote`).
- `AIProviderPreference.effectiveProvider` prefers the selected Claude/Gemini provider, falls back to the only keyed provider, and returns nil with no keys. Chat and summaries use it; tag suggestion does **not** and remains Gemini-only. The Gemini model constant in `GeminiClient.swift` is the one place to update on model retirement.
- Notebook summary regeneration is triggered only by `NotesLibraryViewModel` creating a **paper-linked** note. Edits, deletes, notebook/unlinked note creation, and lazy primary-note creation do not trigger it. A persisted subtree note-count guard requires net growth, and a shared actor coalesces/serializes work (`NotebookSummaryService`).
- Drag payloads are plain strings: `paper:<id>` and `notebook:<id>` (`LibraryViewModel`, `PaperCardView`, `NotebookTreeView`).
- Chat scopes can own multiple sessions. Recency ordering is `updated_at`, then `created_at`, then SQLite `rowid` as the final tiebreak; `scope_id` has no FK, so paper deletion cleans paper chat rows explicitly (`ChatSessionRepository`, `LibraryViewModel.deletePapers`).
- Graph mode is not a fourth pager page: it overlays edges within Free Space; every paper is a node and an edge exists when two papers share at least one tag (`FreeSpaceCanvasView`).
- AI-assisted note-taking proposals are **ephemeral**: located suggestions are drawn as a separate PDFKit annotation track that `rehydrate()` never touches. Nothing is written to the DB until the user accepts, at which point it becomes an ordinary yellow `highlight` (no schema change, no `search_index` write — highlights aren't indexed). Suggestions must be verbatim substrings of the page; the locator tries an exact match then a whitespace-insensitive regex, and silently drops any sentence it can't place on the page. While AI Notes is on, page changes trigger a 500 ms-debounced fetch; results are cached per page (`proposalsByPage`/`fetchedPages`, fetched at most once per document load, redrawn on revisit), `inFlightPages` blocks duplicate concurrent fetches, and a `proposalGeneration` token makes stale async responses (old page/mode/document) no-ops. Accept/dismiss mutate the page cache so choices persist across scrolling. Gemini-only, page-scoped (`KeyIdeaSuggestionService`, `PDFKitWrapper.Coordinator`, `HighlightRenderer.locate`).
- Selecting a specific notebook now shows its **direct** papers only (`reloadPapers` filters the recursive `papersUnder` result to `notebookId == id`), because its subfolders render as their own cards; showing the full recursive subtree would list a subfolder's papers twice. `.all`/`.unfiled` are unchanged, and subfolder cards still use recursive `papersUnder` (via `LibraryViewModel.folderPreview`) for their pile thumbnail and count (`LibraryViewModel`, `PaperGridView`, `PaperListView`, `FreeSpaceCanvasView`).
