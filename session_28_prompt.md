# Session 28: Build CURRENT_STATE.md + CLAUDE.md for Token Efficiency

## Agent Orchestration
If this session's usage crosses ~85% of budget before all tasks below are complete,
stop assigning further implementation work to Sonnet subagents. Instead, orchestrate
the remaining unfinished tasks using the local `codex` CLI (already installed on this
machine) as the implementing agent — hand off clearly scoped task descriptions to it
rather than continuing to consume Sonnet context. Finish the task currently in progress
before handing off, so nothing is left half-written with no assigned agent.

## Context

This session is not a feature or bug-fix session — it's about reducing how much
context/tokens future sessions need to spend re-orienting themselves. Right now, every
session gets started by attaching the original paper_reader_spec.md (which only
describes Phases 1-4 and is badly out of date after 27 sessions of actual work) plus
that session's own prompt. That means paying, every session, to re-derive the gap
between the original plan and what's actually been built. Fix this by producing two
living reference documents that replace the stale spec going forward.

## Goal for this session

### 1. CURRENT_STATE.md - replaces paper_reader_spec.md as the attached reference

Read through the actual codebase (not the old spec, not old session prompts - the
real source of truth is the code itself) and produce a current, accurate document
covering:

- Full current DB schema - every table and column as they actually exist right now,
  including everything added across all migrations to date (Sessions 1, 10, 11, 12,
  13, 17, 19, 22, 23, and any others that touched the schema). Don't reproduce the
  original spec's schema and call it done - diff against the actual migration files.
- Actual file/folder structure - the real layout of the project as it stands, not
  the Session 1 proposal.
- Feature inventory - a concise list of what's actually implemented (not planned),
  organized by area (reading/annotation, notes, organization, window management,
  Claude/Gemini panels, appearance), similar in spirit to the Quick Tips content from
  Session 15 but written for an implementing agent rather than an end user - terser,
  more technical, no need to explain why something exists, just what exists and
  where the relevant code lives.
- Known quirks/non-obvious decisions worth remembering - things a future session
  could easily get wrong by assuming the "obvious" implementation instead of what was
  actually chosen. Examples of the kind of thing to capture (verify each against the
  actual code rather than trusting this list blindly, since some of these may have
  changed since they were decided): reading-status auto-sets to read at 100% progress
  but allows manual override; Focus Mode hides other apps via
  NSRunningApplication.hide(), not the Accessibility API; shift-click selects exactly
  two papers, not a range; the AI panel's paper/notebook context is opt-in via a
  toggle, not automatic; notes are stored as RTF (body_rtf) with a derived plain-text
  body column for search; graph view treats papers (not notes) as nodes.
- Keep this document tight and skimmable - it should be something an agent can read in
  under a minute and immediately know where things stand, not a re-run of the original
  40-page spec.

### 2. CLAUDE.md - hard conventions, loaded automatically by Claude Code every session

Create or update the project's CLAUDE.md with the conventions that have been
established across sessions so far, so future sessions don't have to rediscover them.
At minimum, include:
- UUID string primary keys (not autoincrementing integers)
- Migrations are additive only - never edit a previously-shipped migration file
- Reuse the existing accent-color/theme-update helper (from Session 12) for any new
  UI element that should reflect the macOS system accent color, rather than
  reimplementing it
- Reuse existing debounced-autosave patterns (from Session 4) rather than writing a
  new debounce mechanism per feature
- Any other cross-cutting convention you find actually being followed consistently in
  the codebase as you read through it for Task 1 - add it here if it's the kind of
  thing a new session could easily get wrong by guessing

### 3. Stop attaching stale material going forward

Note explicitly, in whichever of these two files is more appropriate (probably
CURRENT_STATE.md's header), that paper_reader_spec.md and individual past session
prompt files are historical record only and should not be attached as working context
for new sessions - CURRENT_STATE.md and CLAUDE.md are the up-to-date replacements.

## Non-goals

- No code changes, no new features, no bug fixes this session - this is documentation
  only, derived from reading the existing codebase
- No need to preserve every historical detail from the original spec - this replaces
  it, doesn't supplement it

## Deliverable

Two files at the project root: CURRENT_STATE.md (accurate schema, file structure,
feature inventory, and known quirks, verified against actual code) and CLAUDE.md
(hard conventions). Tell me the file sizes/length of each relative to the original
spec, and flag anything in the codebase that surprised you or didn't match what you
expected going in - that's useful signal about where documentation drift had gotten
the worst.
