# Session 6: Page Thumbnail Sidebar + Claude Panel (Paper Scope)

## Context

Continuing "Paper Reader." Sessions 1–5 built the DB layer, PDF import/viewer,
highlighting/comments, the notes window, notebooks/tags/search, and proper `.app`
packaging with an icon. This session has two parts again, like Session 5. Part A is a
reader UI feature — a left-side page thumbnail sidebar, like Preview.app. Part B is the
first version of the Claude side panel described in the original spec — paper-scoped
Q&A, slide-out from the right, backed by your own Anthropic API key.

Full project spec is attached (paper_reader_spec.md) — refer to §3 Phase 3 for the
Claude panel scope, and §4 for the exact context-assembly template and token-budget
approach to use for the paper-scope system prompt. Part A isn't in the original spec's
phase breakdown — it's a reader-quality addition, treat it as its own self-contained
piece of work independent of Part B.

## Part A: Page Thumbnail Sidebar

1. Add a collapsible left sidebar to `PDFReaderView`, similar in spirit to the
   notebook sidebar but scoped to the currently open paper, not the whole app.
2. Show a scrollable column of page thumbnails, one per page, generated via
   `PDFPage.thumbnail(of:for:)` — reuse the thumbnail-generation approach from
   Session 2's import flow rather than writing a second implementation.
3. Highlight/outline the thumbnail corresponding to the page currently visible in the
   main reader view, and keep it in sync as the user scrolls.
4. Clicking a thumbnail scrolls/jumps the main `PDFView` to that page.
5. Toggle button in the reader toolbar to show/hide the sidebar (default: visible).
6. Cache generated thumbnails per paper (disk or in-memory, your call) so reopening a
   paper doesn't regenerate every page thumbnail from scratch each time — for a
   50-page paper this should feel instant on reopen.

## Part B: Claude Panel (Paper Scope)

1. **Settings / API key entry:**
   - A simple settings screen (menu item or ⌘, ) with a field to paste an Anthropic
     API key
   - Store it via `KeychainService` using the `Security` framework
     (`kSecClassGenericPassword`) — never `UserDefaults`, never a plaintext file, per
     spec §5
   - Panel should show a clear "no API key set" state if empty, with a link to open
     settings, rather than failing silently or crashing on first use
2. **Panel UI:**
   - `ClaudePanelView` as a third pane in an `NSSplitViewController`, slides in from
     the right, toggled via a toolbar button (pick a sensible shortcut, e.g. ⌘⇧A)
   - Standard chat UI: message list, text input, send button
   - Stream responses token-by-token rather than waiting for the full reply
     (`stream: true` on the Messages API call) so it doesn't feel laggy on longer
     answers
3. **`ContextBuilder` (paper scope only for this session):**
   - Implement exactly the paper-scope system prompt template from spec §4: paper
     title/authors, full PDF text (via `PDFPage.string` concatenated across pages),
     and all of that paper's highlights + comments formatted in
   - This gets rebuilt fresh each time the panel is opened for a given paper (or
     each time a message is sent, your call on caching vs. rebuilding — flag which
     you chose)
4. **`ClaudeClient`:**
   - Wraps calls to `https://api.anthropic.com/v1/messages`, model
     `claude-sonnet-4-6`, using the stored Keychain key
   - Handle the common failure modes explicitly rather than letting them crash or
     hang silently: missing/invalid key, network failure, rate limit — show a
     readable error in the chat UI for each
5. **Persistence:**
   - Save the conversation as a `ChatSession` row (scope = `'paper'`, scope_id =
     paper id) so reopening the panel for that paper restores the prior conversation
     instead of starting blank

## Explicit non-goals for this session

- No notebook-scope context or quick-action buttons (Session 7)
- No page thumbnail *editing* (reordering, deleting, rotating pages) — display and
  navigation only
- No multiple simultaneous chat sessions per paper — one ongoing conversation per
  paper is fine for now
- No cost/usage tracking or token count display — just get the flow working

## Constraints / preferences

- Keep Part A and Part B changes reasonably separable in the diff, same reasoning as
  Session 5 — they touch different parts of the app and I may want to review/test
  them independently.
- `ContextBuilder` and `ClaudeClient` should be distinct, testable units (per spec §2's
  file layout: `ContextBuilder.swift`, `ClaudeClient.swift`), not merged into the view.
- Don't build any notebook-scope logic yet even if it looks like an easy extension —
  keep this session's `ContextBuilder` genuinely paper-scope-only so Session 7's diff
  is clean.

## Deliverable

App builds and runs. I should be able to: open a paper, see a left-side thumbnail
sidebar that tracks my scroll position and lets me jump to any page, and separately,
open the Claude panel on the right, ask a question about the paper, get a streamed
answer that's clearly grounded in the actual paper text and my highlights/comments,
close and reopen the paper, and see that conversation still there. Show me the final
file tree and flag any judgment calls — particularly how you chose to cache vs. rebuild
the context on each message, and how errors surface in the chat UI.
