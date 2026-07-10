# Session 9: Window Snapping (Side-by-Side PDFs) + Launch Screen Fixes

## Context

Continuing "Paper Reader." This session has one substantial new feature (window
snapping) and one small fix (launch screen). The snapping feature is genuinely the
most complex UI work in the project so far — treat it as exploratory, and prioritize a
working v1 over a fully polished one. The launch screen fix is small and should be
quick.

## Part A: Window Snapping into Side-by-Side Scrolling

**Behavior:** when the user drags one paper's reader window next to another paper's
reader window (edges touching/close), the two should "snap" together into a single
window containing both PDFs side-by-side, each independently scrollable, sharing one
window frame/title bar instead of two separate windows.

Suggested approach:
1. **Detect proximity while dragging:** track `NSWindow` frame changes during a drag
   (e.g. via `windowDidMove` / `windowWillMove` notifications or a drag-tracking loop)
   for reader windows specifically. When two reader windows' edges come within a small
   threshold (~20pt) of each other and roughly align vertically, treat that as a snap
   trigger.
2. **Merge into a combined window:** on snap, close the two individual windows and
   open (or morph one of them into) a new window containing an `NSSplitViewController`
   with two `PDFReaderView` panes side-by-side, a divider the user can drag to resize
   the split, and each pane keeping its own independent scroll position and zoom level
   — reuse the existing `PDFReaderView`/`PDFKitWrapper` from Session 2/8 for each pane
   rather than building a new PDF-rendering path.
3. **Un-snapping:** provide some way to split back apart into two independent windows
   — e.g. dragging the divider all the way to one edge, or a toolbar button in the
   combined window ("split out") that reopens each pane as its own standalone reader
   window at roughly its prior size/position.
4. **Scope for this session:** support exactly two panes (not three+). If snapping
   logic turns out to be unreliable or overly complex to get right with native
   `NSWindow` drag events, it's acceptable to implement a simpler explicit trigger
   instead (e.g. a "Compare side-by-side" menu action you invoke from one reader
   window, picking the second paper from a list) rather than true drag-to-snap physics
   — flag clearly which version you built and why, since drag-to-snap may not be worth
   fighting AppKit over if it's fragile.

**Non-goals:** no saving/restoring split-window layouts across app relaunch, no
snapping more than two windows, no snapping notes windows (PDF reader windows only).

## Part B: Launch Screen Fixes

Session 8 added a splash screen (icon centered on white, ~1–2s) before the main window
appears.

1. **Shorten the display time** — cut it down to something closer to 400–600ms, or
   tie it strictly to actual startup work (DB check/migration) finishing, whichever is
   shorter, rather than a flat 1–2s artificial delay. It should feel like a quick flash,
   not a deliberate pause.
2. **Swap in the higher-quality icon:** I'm attaching `EasyReader_icon.png` — use this
   as the image shown on the launch screen (replacing whatever lower-res asset Session
   8 used). If this same file should also replace the app's actual `AppIcon` asset set
   in `Assets.xcassets` (regenerating all the required icon sizes from it, same
   approach as before with `sips`), do that too so the launch screen and the real app
   icon match and are both the higher-quality version.

## Deliverable

App builds and runs. I should be able to: open two papers in separate reader windows,
drag one near the other, and have them combine into a single window with both PDFs
scrollable side-by-side (or, if true drag-snap wasn't reliable, a "Compare side-by-side"
action that achieves the same end state — tell me which you went with). Separately, the
launch screen should now be noticeably shorter and use the higher-quality
`EasyReader_icon.png` art, both on the splash and as the app's real icon. Flag any
judgment calls, especially on how you implemented the snap detection.
