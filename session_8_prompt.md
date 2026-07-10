# Session 8: Fixes + Launch Screen

## Context

Continuing "Paper Reader." This is a small session — four targeted fixes/additions
across the existing reader and notes flow, not a new feature phase. No schema changes
expected for most of these; check against the Session 1 schema before adding anything.

## Goal for this session

1. **PDF opens at page size, not stretched/auto-fit-width:**
   - Currently `PDFReaderView` auto-scales to fit width (per Session 2). Change the
     default so a paper opens showing the page at its actual/native size (or a sane
     default zoom like 100%, whichever reads better for a US Letter/A4 page on a
     typical laptop screen) rather than force-fitting to the window width.
   - Keep the ability to zoom/fit-width manually if that control already exists —
     this is about the *default* on open, not removing zoom functionality.

2. **Open the linked PDF from within the notes window:**
   - Session 4 added the ability to insert a highlight reference into a note
     (`[p.3: "..."]` style link, storing the highlight id in `linked_highlight_ids`).
     Right now clicking that reference brings the *existing* reader window to that
     page if one's open, but there's no way to open the PDF at all if the reader
     window for that paper isn't already open.
   - Fix: clicking a highlight reference (or a general "open PDF" button in the notes
     window if the note isn't tied to any specific highlight) should open the
     `PDFReaderView` for that note's paper if it's not already open, then jump to the
     relevant page — not just fail silently or do nothing when the reader window
     doesn't exist yet.

3. **Delete notes, from both entry points:**
   - From the notes window itself: a delete action (button or menu item) that removes
     the current `Note` row from the DB and closes the window.
   - From wherever a note can currently be opened via a paper (e.g. a paper detail
     view, card context menu, or however Session 4/5 surfaced "open this paper's
     note") — add a delete option there too, so the user isn't forced to open a note
     just to delete it.
   - Confirm before deleting (simple alert, "Delete this note? This can't be undone")
     — don't delete on a single accidental click.
   - Deleting a note should NOT delete the highlights it referenced — only the note
     row and its `linked_highlight_ids` list go away; the underlying highlights and
     comments are untouched.

4. **Launch screen:**
   - A brief launch/splash screen shown for ~1–2 seconds on app start, before the main
     window appears: just the app icon centered on a plain white background, no text,
     no spinner.
   - Use the standard macOS approach for this (e.g. a `LaunchScreen` storyboard/scene,
     or a lightweight SwiftUI window shown first and dismissed on a timer/once initial
     DB setup completes) — whichever is more idiomatic for the project's current
     SwiftUI app lifecycle, your call, just flag which you used.
   - Don't block real startup work (DB migration check, etc.) behind an artificial
     delay longer than needed — if DB setup finishes faster than the splash's minimum
     display time, that's fine, just don't make the splash itself slower than
     necessary.

## Explicit non-goals for this session

- No new features beyond these four fixes
- No changes to notebook/tag/search behavior
- No changes to the Claude panel (Session 6/7 work)
- No schema changes unless you find one of these genuinely requires it (flag it if so
  — none of the four should need one)

## Deliverable

App builds and runs. I should be able to: open a paper and see it at native page size
by default; click a highlight reference inside a note whose reader window isn't open
and have the PDF open to the right page; delete a note both from inside the notes
window and from the paper-side entry point, with a confirmation prompt either way; and
see a brief icon-on-white splash screen on launch before the main window appears. Flag
which launch-screen approach you used and any judgment calls on the other three.
