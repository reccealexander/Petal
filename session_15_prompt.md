# Session 15: Quick Tips / Help Window + Optional Spotify Panel

## Agent Orchestration
If this session's usage crosses ~85% of budget before all tasks below are complete,
stop assigning further implementation work to Sonnet subagents. Instead, orchestrate
the remaining unfinished tasks using the local `codex` CLI (already installed on this
machine) as the implementing agent — hand off clearly scoped task descriptions to it
rather than continuing to consume Sonnet context. Finish the task currently in progress
before handing off, so nothing is left half-written with no assigned agent.

## Context

Continuing "Paper Reader." This session now has three pieces, in strict priority
order: (0) two blocking regressions from Session 14 that currently make the app
unusable on launch — fix these first, no exceptions; (1) a required in-app help/
reference window documenting everything built across Sessions 1–14; (2) an optional,
lower-priority Spotify playback panel, attempted only if there's budget left after 0
and 1.

## 0. Priority bug fixes — Session 14 regressions

Two regressions surfaced after Session 14's transparency work. **Fix both of these
before starting Task 1 or Task 2 below** — the app is currently broken on launch.

1. **Main window is blank on launch:** since Session 14, the main library window opens
   with no visible content at all — no toolbar, no paper thumbnails, nothing rendered.
   Reproduce from a genuinely fresh launch (quit and relaunch, not just toggling
   settings mid-session) before fixing. Likely candidates, in rough order of
   suspicion:
   - The transparency slider's persisted value is being read as 0 (or an
     uninitialized default) on cold launch rather than the actual saved setting,
     driving chrome alpha to fully invisible from the start.
   - The two-layer compositing from Session 14 (chrome layer vs. content layer) is
     accidentally applying the chrome alpha to the content/card layer too, hiding
     thumbnails along with the toolbar/sidebar chrome instead of keeping content
     opaque as specified.
   - An `NSVisualEffectView` material change from Session 14 is rendering behind
     content rather than behind just the chrome, effectively occluding everything.
   Find and fix the actual cause — don't just force alpha to 1 as a band-aid if the
   real bug is in how the persisted setting is read or how the two layers are wired.

2. **Modifying the transparency slider crashes the app:** reproduce by opening
   Preferences and dragging the slider, capture the actual crash log/stack trace, and
   fix the real cause. Likely candidates:
   - A force-unwrap on an `NSVisualEffectView` or window reference that's `nil` in
     some state
   - A window-appearance update happening off the main thread
   - A divide-by-zero or out-of-range issue in the alpha-interpolation curve built for
     the 1–100 slider range in Session 14

Both should be treated as regressions in Session 14's transparency feature
specifically — check that code first rather than searching elsewhere. Confirm the fix
by launching fresh, opening Preferences, and dragging the slider across its full range
without a crash or a blank window at any point.

## 1. Quick Tips / Functionality window (Settings)

- A new section or window reachable from Settings, listing every feature built so far
  in plain language, organized by area, with keybinds called out explicitly.
  Suggested grouping (adjust as needed to match what actually got built):
  - **Reading & annotation:** highlighting + colors, comment popovers, page
    thumbnail sidebar, page earmarking
  - **Notes:** detached notes window, linking highlights into notes, deleting notes
  - **Organization:** notebooks/nesting, tags (+ autocomplete), pinning, All Folders,
    view modes (Grid/List/Free Space/Graph) and how to switch between them
  - **Selection & window management:** click-to-select vs. click-to-open,
    shift-click, `⌘O` side-by-side, deleting papers, universal window joining
  - **Claude panel:** paper-scope vs. notebook-scope Q&A, quick actions
  - **Appearance:** transparency slider, Focus Mode (and how to exit it),
    `Shift+\`` search
- Keep this as structured content (a simple list/table view is fine, doesn't need to
  be fancy) that's easy to extend as future sessions add more features — don't
  hardcode it in a way that makes appending new entries painful.

## 2. OPTIONAL: Spotify playback panel

Flagged by the user as exploratory/uncertain — attempt only if the help window above
is done and there's session budget left; skip and note as deferred otherwise.

- A slide-out panel (same visual pattern as the Claude panel — third pane, toggled
  from the toolbar) showing now-playing track info with play/pause, skip, and
  rewind/previous controls, via the Spotify Web API.
- **Important scope note to flag to the user, not just implement silently:** unlike
  the Anthropic/Gemini integrations, Spotify's Web API requires OAuth
  (authorization-code flow) against a Spotify Developer app that the user must
  register themselves at developer.spotify.com — there's no simple drop-in API key.
  This session cannot be fully tested end-to-end without the user providing a Client
  ID (and completing OAuth once) from their own registered Spotify app. If that's not
  available, implement as far as possible (panel UI, OAuth flow scaffolding, token
  storage in Keychain following the existing pattern) and clearly state what's left
  to test once credentials are available, rather than claiming it's fully working.

## Non-goals

- No changes to any feature from prior sessions beyond documenting them
- No Spotify features beyond play/pause/skip/previous (no playlists, search, queue
  management)

## Deliverable

App launches to a fully visible main window with toolbar and paper thumbnails
rendering correctly, and dragging the transparency slider in Preferences no longer
crashes the app across its full range — with the actual root cause identified and
fixed for both, not papered over. Settings also has a Quick Tips section covering
every feature from Sessions 1–14 with correct keybinds. If time allows, a Spotify
panel exists with UI and OAuth scaffolding in place — flag exactly what is and isn't
verified working, given the credential dependency. If Spotify wasn't attempted, say so
plainly rather than leaving it ambiguous. Flag the root causes found for both Session
14 regressions in detail — those are the most important findings from this session.
