# Paper Reader — Technical Spec (v1)

Native macOS app for reading, annotating, and organizing scientific papers, with an integrated Claude side panel for context-aware Q&A.

**Stack:** SwiftUI (shell) + AppKit/PDFKit (rendering) + GRDB.swift (SQLite) + Keychain (API key) + Anthropic API (BYO key).

---

## 1. Data Model

SQLite schema (via GRDB.swift), stored at `~/Library/Application Support/PaperReader/db.sqlite`. PDFs themselves copied into `~/Library/Application Support/PaperReader/Papers/<paperId>.pdf`.

```sql
CREATE TABLE notebook (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    parent_id TEXT REFERENCES notebook(id) ON DELETE CASCADE,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    sort_order INTEGER DEFAULT 0
);

CREATE TABLE paper (
    id TEXT PRIMARY KEY,
    notebook_id TEXT REFERENCES notebook(id) ON DELETE SET NULL,
    title TEXT,
    authors TEXT,
    doi TEXT,
    arxiv_id TEXT,
    file_path TEXT NOT NULL,       -- relative path under Papers/
    page_count INTEGER,
    imported_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    last_opened_at DATETIME
);

CREATE TABLE tag (
    id TEXT PRIMARY KEY,
    name TEXT UNIQUE NOT NULL
);

CREATE TABLE paper_tag (
    paper_id TEXT REFERENCES paper(id) ON DELETE CASCADE,
    tag_id TEXT REFERENCES tag(id) ON DELETE CASCADE,
    PRIMARY KEY (paper_id, tag_id)
);

CREATE TABLE highlight (
    id TEXT PRIMARY KEY,
    paper_id TEXT REFERENCES paper(id) ON DELETE CASCADE,
    page INTEGER NOT NULL,
    bounding_boxes TEXT NOT NULL,  -- JSON array of CGRect
    color TEXT DEFAULT 'yellow',   -- yellow/green/blue/pink -> user-assignable categories
    selected_text TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE comment (
    id TEXT PRIMARY KEY,
    highlight_id TEXT REFERENCES highlight(id) ON DELETE CASCADE, -- nullable
    paper_id TEXT REFERENCES paper(id) ON DELETE CASCADE,
    body TEXT NOT NULL,            -- markdown
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME
);

CREATE TABLE note (
    id TEXT PRIMARY KEY,
    paper_id TEXT REFERENCES paper(id) ON DELETE CASCADE,   -- nullable
    notebook_id TEXT REFERENCES notebook(id) ON DELETE CASCADE, -- nullable
    title TEXT,
    body TEXT NOT NULL,            -- markdown
    linked_highlight_ids TEXT,      -- JSON array
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME
);

CREATE TABLE chat_session (
    id TEXT PRIMARY KEY,
    scope TEXT NOT NULL,           -- 'paper' | 'notebook'
    scope_id TEXT NOT NULL,
    messages TEXT NOT NULL,        -- JSON array of {role, content, timestamp}
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME
);

-- Full-text search across the stuff you'd actually want to search
CREATE VIRTUAL TABLE search_index USING fts5(
    entity_id, entity_type, paper_id, content
);
```

`notebook.parent_id` self-reference gives you arbitrary nesting. Recursive queries (e.g. "all papers under Research > 2D Materials, including subfolders") use a `WITH RECURSIVE` CTE:

```sql
WITH RECURSIVE sub_notebooks(id) AS (
    SELECT id FROM notebook WHERE id = :rootId
    UNION ALL
    SELECT n.id FROM notebook n JOIN sub_notebooks s ON n.parent_id = s.id
)
SELECT * FROM paper WHERE notebook_id IN (SELECT id FROM sub_notebooks);
```

---

## 2. App Structure

```
PaperReader/
├── App/
│   ├── PaperReaderApp.swift          # @main entry, WindowGroup setup
│   └── AppState.swift                 # global observable state (selected notebook, open paper, panel visibility)
├── Models/                            # GRDB record structs matching schema above
├── Database/
│   ├── DatabaseManager.swift          # migrations, connection pool
│   └── Migrations/
├── Views/
│   ├── Home/
│   │   ├── HomeView.swift             # sidebar (notebook tree) + main grid (paper cards)
│   │   ├── NotebookTreeView.swift     # recursive folder tree, drag-drop reordering
│   │   └── PaperCardView.swift        # thumbnail, title, tags, last-opened
│   ├── Reader/
│   │   ├── PDFReaderView.swift        # SwiftUI wrapper around NSViewRepresentable(PDFView)
│   │   ├── PDFKitWrapper.swift        # NSViewRepresentable, handles selection/annotation events
│   │   ├── HighlightPopover.swift     # comment entry UI anchored to selection
│   │   └── ReaderToolbar.swift        # highlight color picker, panel toggle, notes toggle
│   ├── Notes/
│   │   └── NotesWindow.swift          # separate NSWindow, markdown editor (paper- or notebook-scoped)
│   └── ClaudePanel/
│       ├── ClaudePanelView.swift      # slide-out panel, chat UI
│       ├── ContextBuilder.swift       # assembles paper/notebook context (see §4)
│       └── ClaudeClient.swift         # Anthropic API calls, streaming
├── Services/
│   ├── PDFImportService.swift         # copy file in, extract page count/text, thumbnail gen
│   ├── KeychainService.swift          # store/retrieve API key
│   ├── SearchService.swift            # FTS5 queries
│   └── MetadataFetchService.swift     # (Phase 5) arXiv/DOI lookup
└── Resources/
```

---

## 3. Phase Breakdown

### Phase 1 — MVP reader
- `PDFImportService`: drag-drop or file picker → copy PDF into `Papers/`, extract title/page count (from PDF metadata or first-page heuristics), generate thumbnail
- `PDFKitWrapper`: wrap `PDFView`, detect text selections via `PDFView.currentSelection`, convert selection to page-relative bounding boxes
- Highlighting: on selection + toolbar color pick, create a `PDFAnnotation(subtype: .highlight)` on the page **and** persist a `Highlight` row
- Comment popover: `NSPopover` anchored to the highlight's screen rect, markdown text field, saves to `Comment` table linked to `highlight_id`
- Notes window: separate `NSWindow`, one per paper, simple markdown `TextEditor`, persists to `Note` table with `paper_id` set
- Home page: flat grid of paper cards (folders come in Phase 2)

### Phase 2 — Notebooks & organization
- `NotebookTreeView`: recursive disclosure-group sidebar, drag papers between notebooks, drag notebooks to nest
- Tags: many-to-many, filter chips on home page
- `SearchService`: FTS5-backed search bar, results grouped by paper/note/comment, jump-to-highlight on click

### Phase 3 — Claude panel (paper scope)
- `ClaudePanelView`: `NSSplitViewController` third pane, toggle via toolbar button (⌘⇧A or similar), animates in/out
- `KeychainService`: store Anthropic API key via `Security` framework (`kSecClassGenericPassword`), settings screen to input/replace it
- `ContextBuilder` (paper mode): pulls full PDF text (`PDFPage.string` concatenated), plus all highlights + comments for that paper, formats into a system prompt
- `ClaudeClient`: calls `/v1/messages` with streaming (`stream: true`), renders incrementally in chat UI
- Chat persisted per paper via `ChatSession` (scope = 'paper', scope_id = paper.id)

### Phase 4 — Notebook-scope context + quick actions
- `ContextBuilder` (notebook mode): token-budget-aware — always includes every highlight + comment + note text across papers in the notebook (usually small); includes full paper text only if it fits within budget, otherwise falls back to a per-paper summary (first pass: use the paper's own highlights as its "summary" if raw text doesn't fit)
- Quick-action buttons in panel: "Explain this equation" (sends current selection + surrounding paragraph), "Summarize this section," "How does this relate to other papers in this notebook" (triggers notebook-scope context)
- Chat history switch: panel shows a session picker if you have both a paper-scope and notebook-scope conversation active

### Phase 5 — Nice-to-haves (backlog, not required for a working app)
- LaTeX rendering in notes: SwiftMath (native) or embed a small WKWebView running KaTeX
- arXiv/DOI metadata autofetch on import (populate title/authors automatically)
- Backlinks: when a note references another paper/note by `[[title]]`, show "linked from" on the target
- Export notebook to a single reviewed markdown/PDF doc (papers + your notes + highlights, concatenated)

---

## 4. Claude Panel — Context Assembly Detail

**Paper-scope system prompt template:**
```
You are helping the user understand a scientific paper they're reading.

Paper title: {title}
Authors: {authors}

Full text:
{pdf_text}

The user has made these highlights and comments while reading:
{highlights_and_comments_formatted}

Answer the user's questions about this paper. Reference specific sections,
equations, or their own annotations where relevant.
```

**Notebook-scope system prompt template:**
```
You are helping the user think across a collection of papers in their
notebook "{notebook_name}".

Papers in this notebook:
{for each paper: title, authors, and that paper's highlights/comments}

{if token budget allows: full text of each paper, else omitted}

Answer questions that may span multiple papers — connections, contradictions,
open questions the user has raised in their notes.
```

**Token budgeting (rough heuristic):**
- Claude Sonnet context window is large, but you still don't want to blindly stuff 10 papers' full text in every message
- Rule of thumb: highlights + comments + notes are always included (typically a few KB, cheap)
- Full raw PDF text included only when (a) paper-scope, or (b) notebook-scope with ≤3 papers and combined text under ~50k tokens
- Beyond that, fall back to per-paper "highlight digest" (title + your highlights/comments only, no raw text) and let the user explicitly ask to pull in full text for a specific paper if needed

---

## 5. Key Implementation Notes

- **PDFKit annotations vs DB as source of truth:** write highlights to both — `PDFAnnotation` for visual rendering (and so the PDF looks annotated if opened in Preview), DB row for querying/search/Claude context. On paper open, if DB and PDF annotations ever diverge, DB wins (rebuild PDFKit overlay from DB).
- **API key security:** never store in `UserDefaults` or plaintext files — Keychain only, via `Security` framework's generic password APIs.
- **Copy-on-import:** since PDFs are copied into app storage, you'll want a "reveal in Finder" / "show original import path" convenience, and probably a dedupe check (hash the file, warn if this paper's already been imported).
- **Streaming responses:** Anthropic's Messages API supports `stream: true` (SSE) — worth implementing from Phase 3 onward so the panel doesn't feel laggy on long answers.

---

## 6. Suggested build order for Claude Code sessions

Given the phase breakdown above, a reasonable way to delegate this in Claude Code:
1. Session 1: DB schema + GRDB setup + migrations, empty SwiftUI shell
2. Session 2: PDF import + PDFKit viewer (no annotation yet) — get render pipeline solid first
3. Session 3: Highlighting + comment popover
4. Session 4: Notes window
5. Session 5: Notebook tree + tags + FTS5 search
6. Session 6: Claude panel (paper scope) + Keychain
7. Session 7: Notebook-scope context + quick actions
