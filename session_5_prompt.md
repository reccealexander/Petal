# Session 5: Notebooks, Tags, Search + App Icon/Packaging

## Context

Continuing "Paper Reader." Sessions 1–4 built the DB layer, PDF import/viewer,
highlighting/comments, and the detached notes window. Everything so far has been a
flat list of papers with no real folder structure, and the app has been run only from
Xcode — no icon, no proper standalone `.app` you can launch from Finder/Dock/Spotlight
like a normal Mac app.

This session has two distinct parts. Part A is the Phase 2 feature work (notebooks,
tags, search). Part B is unrelated to features — it's making the app actually feel like
an installed application rather than something only launchable from Xcode. Treat them
as two separable chunks of work; Part B doesn't depend on Part A at all and could
technically be done first if that's easier to sequence.

Full project spec is attached (paper_reader_spec.md) — refer to §1 for the `Notebook`,
`Tag`, `PaperTag` schema and the recursive CTE query pattern, and §3 Phase 2 for scope.

## Part A: Notebooks, Tags, Search

1. **Notebook tree (sidebar):**
   - Recursive `NotebookTreeView` — disclosure groups, arbitrary nesting via
     `notebook.parent_id`
   - Create/rename/delete notebooks (delete should prompt if it contains papers —
     decide and tell me whether papers get orphaned to "no notebook" or the whole
     subtree cascades, matching the schema's `ON DELETE SET NULL` for `paper.notebook_id`
     and `ON DELETE CASCADE` for nested notebooks themselves)
   - Drag a paper card onto a notebook in the sidebar to move it there
   - Drag a notebook onto another to nest it
   - Use the recursive CTE from spec §1 to fetch "all papers under this notebook,
     including subfolders" for the main grid view
2. **Tags:**
   - Simple tag creation/assignment on a paper (e.g. a tag field in a paper detail
     popover, or inline chips on the card)
   - Filter chips on the home screen — clicking a tag filters the current view to
     papers with that tag (combine with whatever notebook is currently selected, don't
     make tag-filtering and notebook-filtering mutually exclusive)
3. **Search:**
   - Search bar on the home screen, backed by the `search_index` FTS5 virtual table
     from the schema
   - You'll need to actually populate `search_index` — insert/update rows whenever a
     paper's title, a note's body, or a comment's body changes (trigger this from the
     existing repository/save methods rather than as a separate manual sync step)
   - Results should show entity type (paper title match / note match / comment match)
     and jump to the right place on click: paper → home card, note match → open that
     paper's notes window, comment match → open the paper and scroll to that highlight

## Part B: App Icon + Standalone `.app` Packaging

1. **App icon:**
   - Add an `AppIcon` asset set to `Assets.xcassets` with placeholder artwork for now
     (a simple generated icon is fine — doesn't need to be final branding, just needs
     all the required sizes filled in: 16/32/128/256/512 pt at 1x and 2x, per Apple's
     `.icns` requirements) so Xcode doesn't warn about missing icon sizes
   - Confirm `Info.plist` / build settings correctly reference it (`CFBundleIconFile`
     if needed, though modern Xcode usually handles this via the asset catalog
     automatically — just verify it actually shows up)
2. **Bundle identity:**
   - Set a proper `CFBundleIdentifier` (e.g. `com.alexanderrecce.paperreader` — adjust
     to whatever reverse-DNS you want) and `CFBundleDisplayName` ("Paper Reader")
     instead of Xcode's default placeholder values
3. **Standalone launch:**
   - Confirm a Release build produces a `PaperReader.app` that can be copied to
     `/Applications` (or run from anywhere) and double-clicked to launch — no Xcode
     required, no "damaged and can't be opened" Gatekeeper issue for local/unsigned
     use (ad-hoc signing is fine for personal use; don't set up notarization/distribution
     signing unless I ask for that separately)
   - Confirm the app correctly finds/creates its DB and `Papers/` directory under
     `~/Library/Application Support/PaperReader/` when launched this way (not just
     when run from Xcode's debug environment — these can behave differently)
   - Tell me exactly where the built `.app` ends up after an Xcode Release archive/build
     so I know where to grab it from

## Explicit non-goals for this session

- No Claude panel (Session 6)
- No App Store distribution, notarization, or Developer ID signing — this is for your
  own local use only, not distribution
- No custom/final icon artwork — placeholder is fine, you can swap the actual image
  file later without touching any code
- Search is basic FTS5 matching, not fuzzy/ranked relevance tuning

## Constraints / preferences

- Reuse notebook/tag schema and models from Session 1 as-is — no new migrations needed
  for Part A.
- Keep Part B changes (icon, bundle ID, build settings) isolated from Part A's feature
  code so they're easy to review independently in the diff.

## Deliverable

App builds and runs with: a working notebook sidebar (create/nest/drag papers into
folders), tag filtering, and a working search bar that finds papers/notes/comments and
jumps to them. Separately: a Release build produces a real `PaperReader.app` with an
icon, that launches by double-clicking from Finder without Xcode running, and correctly
uses the same `~/Library/Application Support/PaperReader/` data as the dev build. Tell
me where to find the built `.app`, and flag your decision on the notebook-delete
orphaning behavior.
