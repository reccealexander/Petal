# Session 20: Pin Indicator, Notes Button Coloring, Dual AI Provider Keys

## Agent Orchestration
If this session's usage crosses ~85% of budget before all tasks below are complete,
stop assigning further implementation work to Sonnet subagents. Instead, orchestrate
the remaining unfinished tasks using the local `codex` CLI (already installed on this
machine) as the implementing agent — hand off clearly scoped task descriptions to it
rather than continuing to consume Sonnet context. Finish the task currently in progress
before handing off, so nothing is left half-written with no assigned agent.

## Context

Continuing "Paper Reader." Three fixes/additions: a missing visual indicator for
pinned papers, consolidating the notes indicator into the notes button itself instead
of two separate elements, and restoring dual AI provider support (Claude + Gemini,
both available, user picks).

## 1. Pinned indicator

Session 12 added pin functionality (sorts pinned papers/notebooks to the top) but no
visible marker on the card itself — there's currently no way to tell a paper is pinned
just by looking at it. Add a small, clear indicator (e.g. a pin/thumbtack icon in a
corner of the card) shown on any paper card that's pinned, across all view modes (Grid,
List, Free Space) and in the All Folders view for pinned notebooks. Keep it visually
distinct from the notes indicator and bookmark indicators from Sessions 12–13 — don't
let these badges start colliding or looking ambiguous as more of them stack up on one
card; if multiple indicators need to coexist on a single card, arrange them in
consistent, non-overlapping corners.

## 2. Merge notes indicator into the notes button

Currently (Session 12) there's a separate colored badge showing a paper has a linked
note, distinct from whatever button opens that note. Consolidate these: remove the
separate badge, and instead make **the notes-open button itself** the indicator —
rendered in the macOS accent color (`NSColor.controlAccentColor`, same convention as
before) when the paper has a linked note, and default system gray when it doesn't.
Clicking it still opens/creates the notes window as before (Session 4). Apply this
consistently everywhere the notes button appears (reader toolbar, paper card in any
view mode where such a button exists).

## 3. Dual AI provider support (Claude + Gemini)

Restore/ensure both API key fields exist in Settings simultaneously — **adding or
editing one must not remove or overwrite the other.** If the current implementation
has a bug where saving the Gemini key clears the Anthropic key (or vice versa), fix
that as the first step; each should be its own independent Keychain entry per the
original design (Session 6 for Anthropic, Session 10 for Gemini).

Beyond just coexisting, add a **provider selector** in Settings (e.g. a segmented
control or dropdown: "Claude" / "Gemini") for AI features that aren't already
architecturally fixed to one provider. Concretely for this session:
- The **notebook AI summary** feature (Session 10, currently Gemini-only) should
  become provider-aware: if the user has selected Claude as their preferred provider,
  generate notebook summaries via `ClaudeClient` instead of `GeminiClient` (same
  trigger logic — only regenerate on new notes, same caching columns — just swap which
  client performs the actual generation call).
- The **paper/notebook-scope chat panel** (Session 6/7) is currently built
  specifically around Claude and is a more involved chat/streaming UI. Leave it
  Claude-only for this session rather than attempting to generalize it to both
  providers — that's a larger scope change than this session should take on. Flag this
  explicitly as a decision, and note it as a candidate for a future session if I want
  the chat panel to also support Gemini.
- If the user has only entered one of the two keys, don't force a provider choice that
  has no key behind it — default the selector to whichever provider actually has a key
  set, and disable/hide the other option until a key is added.

## Non-goals

- No changes to the Claude panel's chat UI/streaming behavior itself
- No new AI providers beyond Claude and Gemini
- No changes to bookmark or reading-status indicators beyond keeping them visually
  distinct from the new pin indicator

## Deliverable

App builds and runs. Pinned papers and notebooks show a clear pin icon across every
view where pinning applies. The notes button itself is accent-colored when a note
exists and default gray when it doesn't, with no separate badge remaining. Settings
holds both an Anthropic and a Gemini API key at once without either overwriting the
other, and a provider selector controls which one generates notebook summaries
(disabled/defaulted sensibly if only one key is present). Flag your approach to
indicator layout when multiple badges coexist on one card, and confirm whether a
key-overwrite bug was actually found and fixed in Task 3.
