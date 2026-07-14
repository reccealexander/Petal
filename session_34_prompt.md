# Session 34: iOS + iPadOS Companion App with CloudKit Sync — Architecture & Migration Design

## Nature of this session

This is a **design/specification session — no production code, no migration, no iOS
target is created.** The single deliverable is a committed markdown design document
that a later session can implement from directly. It is writing- and analysis-heavy, so
it is Opus-led end to end; there is no Sonnet/codex implementation handoff to schedule.
Do not create the iOS target, do not add a migration, do not modify `Package.swift`.
Where the document proposes code (schemas, migration shape, service signatures), that is
*design*, written inside the doc — not applied to the tree.

Suggested doc path: `docs/ios_cloudkit_sync_design.md` (create `docs/` if needed).

## Context

"Paper Reader" is today a **local-first macOS app**. Its persistence is GRDB/SQLite plus
a managed `Papers/` directory, both in `~/Library/Application Support/PaperReader/`
(`Database/DatabaseManager.swift`). Entity primary keys are already **UUID strings**
(`paper_tag` is the one composite-key exception); schema is at migrations V1–V9;
`search_index` is a manually maintained FTS5 table with no triggers or foreign keys; API
keys live per-provider in Keychain. The UI is SwiftUI + AppKit (`NSWindow`, PDFKit via an
`NSViewRepresentable` in `Views/Reader/PDFKitWrapper.swift`).

Crucially, `PaperReaderCore` (Models + Database + Services) is a **UI-free SPM library**
and already compiles for iOS *except one line*: an `NSBitmapImageRep` thumbnail call in
`Services/PDFImportService.swift`. Its dependencies (GRDB, PDFKit, CryptoKit,
Security/Keychain) all exist on iOS/iPadOS.

**Goal of the overall effort (multiple sessions):** a full-parity **universal iPhone +
iPad** app, with **full read/write** (a true peer to the Mac, not a viewer), where the
two platforms stay in sync via **CloudKit**. This session designs how to get there.

## Hard constraints the design MUST respect (from `CLAUDE.md`)

These are non-negotiable and bound every decision in the document:

- Keep the SPM boundary. `Core` stays UI-free and **must compile for iOS**; UI stays in
  the app targets.
- **GRDB + SQLite remains the local store on every device.** Do **not** propose ripping
  out GRDB for Core Data / `NSPersistentCloudKitContainer`: the additive-migration
  convention, the FTS `search_index`, snake_case `CodingKeys`, JSON/RTF storage
  encodings, and UUID string PKs are all load-bearing. CloudKit must be designed *around*
  the existing GRDB stack, not as a replacement for it.
- Schema changes are **new additive `V<n>` migrations only**; never edit a shipped one.
- `search_index` has no triggers/FKs — it is a **derived** index, rebuilt locally, and
  must **never** be synced.
- Secrets stay in Keychain and are **never synced in plaintext**.
- Preserve zero-based page indexes and the existing bounding-box/RTF/JSON encodings.

## The document must decide and specify

Write it so a subsequent implementer needs no further architecture decisions. For each
section, make the call; where a decision is genuinely open, state the **recommended
default and the tradeoff** rather than leaving it blank.

### 1. Sync-store architecture
Establish GRDB as the per-device **source of truth** with a **custom CloudKit sync
layer** (e.g. a `CloudSyncService` in `Core`). Briefly evaluate and reject the Core Data
mirroring alternative against the hard constraints above. Specify where CloudKit sits:
**private database**, **custom record zone(s)** (required for delta sync via server change
tokens and atomic multi-record saves).

### 2. CloudKit record schema
One `CKRecord` type per **synced** table: `paper`, `notebook`, `highlight`, `comment`,
`note`, `tag`, `paper_tag`, `page_bookmark`, `chat_session`. For each, map GRDB
columns → record fields (including how JSON columns like `bounding_boxes` /
`linked_highlight_ids` / chat `messages` and the RTF `body_rtf` blob are carried).
State which tables do **not** sync (`search_index`). Specify that UUID string PKs become
`CKRecord.ID.recordName` directly (already globally unique — no ID remapping), and how the
`paper_tag` composite key is represented.

### 3. PDF file sync
PDFs (~11 MB each) as **`CKAsset`** attached to the paper record (or a sibling asset
record — pick and justify). Specify upload on import, **lazy/on-demand download** on
mobile, the local `Papers/` cache per device, and how `file_hash` dedup interacts with
assets so the same PDF isn't re-uploaded.

### 4. Sync engine mechanics
Define **push** (local dirty rows → `CKModifyRecordsOperation`) and **pull**
(`CKFetchRecordZoneChangesOperation` + persisted server change token). Specify the
**per-row sync bookkeeping** this requires and the **new additive migration** that adds
it: a dirty/needs-upload flag, the last-known CloudKit system fields / record change tag
per row, and **tombstones** for deletes (CloudKit has no cascade; local FKs do). Specify
apply-ordering so foreign-key dependencies are satisfied on pull, and how the manual FTS
`search_index` is **rebuilt locally** after applying pulled rows (per the same-transaction
FTS convention).

### 5. Conflict resolution
Per-record policy, table by table. Default to **last-writer-wins** via a monotonic
`updated_at`/change-tag comparison. Note that highlights, comments, and bookmarks are
**append-mostly / low-conflict**; call out `note.body_rtf` as the real risk (field-level
LWW = potential lost update) and give a recommended v1 stance plus a possible mitigation.
Cover organization moves (`notebook_id` reparenting) and deletes-vs-edits via tombstones.

### 6. Account & identity model
CloudKit **private DB** ⇒ single user across *their own* devices (no cross-user sharing in
v1). Specify behavior when there's **no iCloud account / signed out** (local-only,
graceful). API keys stay **per-device in Keychain** (optionally iCloud Keychain) — never
in CloudKit. Decide whether `chat_session` rows sync (recommend yes; they're not secrets).

### 7. Core portability
Enumerate the exact changes to make `Core` build for iOS: the `NSBitmapImageRep`
thumbnail path in `PDFImportService.swift` → a cross-platform image encoding
(`#if canImport(AppKit)` / UIKit), an audit confirming no other AppKit leaks, and the
`Package.swift` change to add the `.iOS` platform and an iOS-safe target arrangement
(design only — do not apply this session).

### 8. iOS / iPadOS UI plan
Full feature parity — **reading + highlights, notes (RTF), notebooks & organization, AI
chat + AI notes** — as a **universal** app (compact iPhone + regular iPad layouts). Map
each macOS surface to its iOS counterpart, marking each as *straight SwiftUI port*,
*needs UIKit/PDFKit rewrite* (the reader: `NSViewRepresentable` → `UIViewRepresentable`),
or *Mac-only, dropped/reimagined* (window joining/compare/snapping, Focus Mode's window
hiding). Confirm reuse **as-is** of `QuickActionPrompts`, `ContextBuilder`, the AI
clients, and the repositories.

### 9. Migration & first-sync rollout
Specify the shape of the new additive **sync-state migration** (call it `V10`, since V1–V9
are shipped) and how existing rows are backfilled as "needs initial upload." Describe the
**bootstrap**: an existing Mac user's local library becomes the CloudKit seed on first
run, and a fresh device pulls it down.

### 10. Session roadmap
Break the epic into sequenced, single-deliverable sessions with explicit dependency order,
e.g.: **35** V10 sync-state migration + `CloudSyncService` skeleton (Mac); **36** Mac
push/pull end-to-end incl. `CKAsset` PDFs, no UI; **37** iOS target + Core compiles for
iOS + minimal local reader; **38** iOS reading/highlights UI; **39** iOS notes +
organization; **40** iOS AI chat + AI notes; **41** conflict/offline/background-sync
hardening. Adjust as the design dictates; one-line deliverable each.

### 11. Risks & open questions
CloudKit quotas and `CKAsset` size limits, large-library initial-sync time, offline/merge
edge cases, RTF conflict, background sync via `CKSubscription`/push, and a **test strategy
for the sync layer** (Core unit tests without a live CloudKit — e.g. a protocol seam over
the CloudKit operations so sync logic is testable with a fake).

## Non-goals (this session)

- **No code, no migration, no iOS target, no `Package.swift` edits** — document only.
- **No cross-user collaboration/sharing** (CloudKit *shared* DB) in v1.
- **No abandoning GRDB** for Core Data/`NSPersistentCloudKitContainer`.
- No redesign of existing macOS features — only mapping them to iOS.
- No visual/UX mockups — this is architecture, not design comps.

## Deliverable

A single committed markdown design document that decides the sync-store architecture,
specifies the CloudKit record schema, the `CKAsset` PDF strategy, the conflict-resolution
rules, the `V10` sync-state migration shape, the Core-portability changes, the
universal-iOS UI mapping, and a session-by-session roadmap — such that Session 35 can
start implementing without re-deciding architecture. Every genuinely-open choice states a
recommended default and its tradeoff. Flag anything about CloudKit + GRDB coexistence you
found surprising or risky.
