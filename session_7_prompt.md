# Session 7: Reader/Organization UX Prerequisites + Notebook-Scope Claude Context

## Context

Continuing "Paper Reader." Sessions 1–6 built the DB layer, PDF import/viewer,
highlighting/comments, detached paper notes, notebooks/tags/search, app packaging,
page thumbnails, and the Claude panel for paper-scoped Q&A using the user's Anthropic
API key.

This session has two ordered parts. **Part A must be completed first** before starting
the actual Session 7 Claude features. Part A adds several reader, notes, tagging,
preferences, and sorting improvements that are needed for the app to feel coherent
before notebook-scope Claude context is added. Part B then implements the original
Session 7 scope from the spec: notebook-scope context and quick actions.

Full project spec is attached (`paper_reader_spec.md`) — refer to §3 Phase 4 for
notebook-scope Claude context + quick actions, and §4 for notebook-scope context
assembly and token-budgeting.

## Part A: Required Prerequisite Features — Complete These First

Implement all of the following before beginning Part B.

### 1. AI-recommended tags on the PDF preview

1. Add AI-recommended tags to the tag button in the top-right area of the PDF preview /
   reader UI.
2. When a paper is open, the tag button should show:
   - Existing user-assigned tags
   - A clearly separated list of AI-recommended tags
3. Recommended tags should be generated from available paper context:
   - Prefer title, authors, abstract/first-page text, existing highlights, comments,
     and notes
   - Do not require the user to manually paste text
4. The user should be able to click a recommended tag to accept/apply it to the paper.
5. Accepted tags should become normal `Tag` / `PaperTag` records using the existing
   Session 5 tagging system.
6. Rejected/ignored recommended tags do not need to be persisted yet, but avoid showing
   duplicate suggestions that already exist as assigned tags.
7. If no Anthropic API key is set, show a graceful fallback state such as
   "Add an API key in Preferences to generate tag suggestions." Do not crash.

### 2. PDF reader should open at page size, not wide-window fit

1. Change the default PDF opening behavior so papers open at a natural page-size /
   page-fit reading width instead of the current overly wide window format.
2. The reader should feel similar to Preview.app's page-sized view:
   - One page centered horizontally
   - Reasonable margins around the page
   - Continuous vertical scrolling preserved
3. Keep zoom controls functional.
4. If the user manually changes zoom, preserve that zoom for the current reader session.
5. Do not break the page thumbnail sidebar from Session 6 — thumbnail navigation and
   current-page tracking must still work.

### 3. Preferences window from menu bar

1. Add a proper Preferences window accessible from the macOS menu bar:
   - App menu → Preferences...
   - Keyboard shortcut: `⌘,`
2. Move or expose existing Anthropic API key settings here if they currently live in a
   separate settings screen.
3. Preferences should include:
   - Anthropic API key entry/replacement
   - Dark/light mode setting
4. Dark/light mode options should include at least:
   - System
   - Light
   - Dark
5. Persist the appearance preference locally.
6. Applying the appearance preference should update the app UI without requiring a
   full app restart if reasonably possible.
7. Continue storing the Anthropic API key only in Keychain, never `UserDefaults` or
   plaintext files.

### 4. Sorting mechanism in the "All Papers" window

1. Add a sorting/view mechanism to the "All Papers" window.
2. The user should be able to sort or view papers by:
   - Notebook
   - Tags
3. This should work alongside existing notebook selection and tag filters from Session 5.
4. Provide a simple UI control such as a segmented picker, dropdown, or toolbar menu.
5. When viewing by notebook:
   - Group papers under their assigned notebook
   - Papers with no notebook should appear under "No Notebook"
6. When viewing by tags:
   - Group papers under tag names
   - Papers with no tags should appear under "Untagged"
   - A paper with multiple tags may appear under multiple tag groups
7. Keep the existing flat/all-papers view available.

### 5. Open linked note from each paper preview/card

1. Add a button on each paper preview/card that opens the note linked to that paper.
2. If the paper already has a primary paper note, clicking the button opens it.
3. If the paper has no linked note yet, clicking the button should create one and open it.
4. Reuse the existing note creation/persistence logic from Session 4 where possible.
5. The button should be visible enough to discover but should not make the card cluttered.
6. Opening a note from the paper card should bring the existing note window to front
   if it is already open, rather than opening a duplicate.

### 6. New "Notes" window/section in the left menu

1. Add an entirely new top-level "Notes" section/window accessible from the left menu
   or sidebar.
2. This Notes section should show notes linked to papers, plus any unlinked notes.
3. It should support creating new notes directly from the Notes section.
4. New notes may be:
   - Linked to a paper
   - Linked to a notebook
   - Unlinked/general
5. The Notes section should display enough metadata to understand each note:
   - Note title
   - Linked paper, if any
   - Linked notebook, if any
   - Tags, if any available through linked paper or note metadata
   - Updated date
6. Add a sorting/filtering mechanism in the Notes section that can sort/view notes by:
   - Notebook
   - Tag
   - Linked vs. unlinked
7. Linked/unlinked view should clearly separate:
   - Paper-linked notes
   - Notebook-linked notes
   - Unlinked notes
8. Creating, opening, editing, and autosaving notes from this Notes section must use
   the same `Note` table and autosave behavior as the existing detached paper notes.
9. Do not create a second parallel note model.

## Part B: Notebook-Scope Claude Context

Only begin this part after all Part A features are implemented.

### 1. Notebook-scope chat mode

1. Extend the Claude panel so it can operate in notebook scope as well as paper scope.
2. Notebook-scope conversations should use `ChatSession` rows with:
   - `scope = 'notebook'`
   - `scope_id = notebook.id`
3. When a notebook is selected, the user should be able to open the Claude panel in
   notebook mode.
4. The panel should clearly indicate whether it is currently answering about:
   - The current paper
   - The current notebook
5. If both paper-scope and notebook-scope conversations exist, provide a simple session
   picker or mode switcher in the panel.

### 2. Notebook ContextBuilder

1. Extend `ContextBuilder` to support notebook mode without breaking paper mode.
2. Use the notebook-scope system prompt template from the spec:
   - Notebook name
   - Papers in the notebook
   - Each paper's title/authors
   - Highlights/comments for each paper
   - Notes associated with papers in the notebook
   - Notes associated directly with the notebook
3. Include papers in nested sub-notebooks using the existing recursive notebook query
   behavior from Session 5.
4. Token-budgeting behavior:
   - Always include highlights, comments, and notes
   - Include full raw paper text only when the notebook contains a small enough number
     of papers and the combined text is within the budget
   - Otherwise fall back to a per-paper digest using title, authors, highlights,
     comments, and notes
5. Make the budget behavior explicit in code and easy to tune later.
6. Keep `ContextBuilder` testable and separate from view code.

### 3. Notebook-scope ClaudeClient integration

1. Reuse the existing `ClaudeClient` from Session 6.
2. Do not duplicate API client logic for notebook mode.
3. Stream notebook-scope responses token-by-token, just like paper-scope responses.
4. Preserve the existing error handling for:
   - Missing API key
   - Invalid API key
   - Network failure
   - Rate limit
5. Errors should appear in the chat UI in readable language.

### 4. Notebook-scope chat persistence

1. Save notebook-scope conversations to `ChatSession`.
2. Reopening the Claude panel for the same notebook should restore the existing
   notebook conversation.
3. Paper-scope and notebook-scope conversations should not overwrite each other.
4. If the user switches between paper and notebook scope, the panel should load the
   correct persisted session.

## Part C: Quick Actions

Implement quick actions after notebook-scope chat works.

### 1. Reader quick actions

Add quick-action buttons in the Claude panel for the current paper:

1. "Explain this equation"
   - Uses the current PDF selection if available
   - Includes nearby surrounding text when possible
   - If no selection exists, show a clear prompt asking the user to select text/equation
2. "Summarize this section"
   - Uses the current page or current selection context
   - Should produce a concise section-level summary
3. "Explain this highlight/comment"
   - If a highlight or comment is selected/open, send that context to Claude
   - Otherwise ask the user to select a highlight/comment first

### 2. Notebook quick actions

Add quick-action buttons for notebook mode:

1. "How does this relate to other papers in this notebook?"
   - Uses the current paper/selection/highlight as the starting point
   - Sends notebook-scope context
2. "Find connections across this notebook"
   - Asks Claude to identify recurring themes, contradictions, methods, or open
     questions across the notebook
3. "Summarize this notebook"
   - Produces a structured summary of the notebook using papers, highlights, comments,
     and notes

### 3. Quick-action UX

1. Quick actions should insert a clear user message into the chat before streaming
   Claude's response, so the conversation history remains understandable.
2. Do not make quick actions hidden-only shortcuts; they should be visible in the panel.
3. Disable or explain unavailable quick actions depending on context.
4. Keep quick-action prompt templates in a dedicated file or helper, not hardcoded
   directly in the SwiftUI view.

## Explicit Non-Goals for This Session

- No multi-user sync
- No cloud storage
- No citation manager integration
- No BibTeX/RIS import/export
- No advanced AI tag management such as bulk approval, rejection history, or tag
  ontology merging
- No full WYSIWYG markdown editor rewrite
- No backlinks beyond what already exists or is needed for opening linked notes
- No cost/usage dashboard
- No notarization, App Store distribution, or external release work

## Constraints / Preferences

- Complete Part A before Part B. Do not start notebook-scope Claude work until the
  prerequisite reader, preferences, sorting, tag, and notes features are working.
- Keep the diff organized so Part A UI/organization changes are reviewable separately
  from Part B/C Claude changes.
- Reuse existing models and schema where possible:
  - `Tag`
  - `PaperTag`
  - `Note`
  - `ChatSession`
  - `Notebook`
  - `Paper`
- Do not create duplicate systems for notes, tags, or preferences.
- Keep API-key storage in Keychain only.
- Keep Claude-related logic out of SwiftUI views:
  - `ContextBuilder`
  - `ClaudeClient`
  - quick-action prompt builder/helper
- Preserve existing functionality:
  - PDF import
  - PDF viewing
  - highlighting/comments
  - detached paper notes
  - notebooks/tags/search
  - thumbnail sidebar
  - paper-scope Claude chat
- App must build and run after each major part.

## Deliverable

App builds and runs. I should be able to:

1. Open a paper and see it at a natural page-sized reading width rather than an overly
   wide layout.
2. Use the top-right PDF tag button to see existing tags and AI-recommended tags, then
   accept a recommended tag.
3. Open Preferences from the menu bar with `⌘,`, update my Anthropic API key, and switch
   between System/Light/Dark appearance modes.
4. Open the "All Papers" window and view/sort papers by notebook or by tag.
5. Click a button on a paper preview/card to open or create the note linked to that paper.
6. Open the new Notes section from the left menu, create notes, open notes, and sort/view
   notes by notebook, tag, or linked/unlinked status.
7. Select a notebook and open Claude in notebook-scope mode.
8. Ask a question across the notebook and get a streamed answer grounded in the papers,
   highlights, comments, and notes in that notebook and its sub-notebooks.
9. Switch between paper-scope and notebook-scope chat without losing either conversation.
10. Use quick-action buttons such as "Explain this equation," "Summarize this section,"
    and "How does this relate to other papers in this notebook?"

Show me the final file tree and flag any judgment calls, especially:

- How AI-recommended tags are generated and when they refresh
- How page-sized PDF opening is configured
- Where preferences are persisted
- How All Papers grouping by notebook/tag is implemented
- How the new Notes section reuses the existing `Note` model
- How notebook-scope context is budgeted
- How quick-action prompt templates are organized
