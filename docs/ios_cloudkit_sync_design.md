# Petal — iOS/iPadOS App + CloudKit Sync: Architecture & Migration Design

**Status:** Design spec (Session 34). No code, migration, or iOS target is created by this
document — it is the plan Session 35 onward implement from.
**Scope:** A full-parity **universal iPhone + iPad** app that is a **read/write peer** of
the macOS app, kept in sync through **CloudKit**.
**Author note:** Field mappings below were read from the current models; the live schema is
at migration **V10** (`V10AddNotebookSummaryPaperSet`), so the new sync-state migration is
**V11**. (`CURRENT_STATE.md` still says "V1–V9" and omits the V10 notebook columns — stale;
worth refreshing in a later session, out of scope here.)

---

## 0. Decisions at a glance

| Question | Decision |
|---|---|
| Local store on each device | **GRDB/SQLite stays** the source of truth. CloudKit is a sync transport, not the store. |
| Sync mechanism | **Custom `CloudSyncService` in Core** mirroring rows ↔ `CKRecord`s. Not Core Data / `NSPersistentCloudKitContainer`. |
| CloudKit database | **Private database**, one **custom record zone** (`PetalZone`) for delta sync + atomic saves. |
| Record identity | UUID string PKs become `CKRecord.recordName` **verbatim** — no ID remapping. |
| PDFs | **`CKAsset`** on a dedicated `pdfAsset` record, downloaded **lazily** on mobile. |
| Sync bookkeeping | New additive **V11** migration: a `sync_state` sidecar table (no changes to existing tables). |
| Conflict policy | **Last-writer-wins** by `updated_at`/change-tag, per record. Tombstones for deletes. |
| Account model | Single user across **their own** iCloud devices. No cross-user sharing in v1. |
| Secrets | API keys stay **per-device in Keychain**, never synced. |
| Repo | **Same repository**, new iOS target — not a new repo (see Appendix A). |

---

## 1. Sync-store architecture

### Decision: GRDB stays; CloudKit is a transport

The `CLAUDE.md` conventions make GRDB **load-bearing**: additive `V<n>` migrations, the
manually-maintained FTS `search_index`, snake_case `CodingKeys`, JSON/RTF column encodings,
and UUID string PKs. `NSPersistentCloudKitContainer` (the turnkey Apple option) requires a
**Core Data** model and its own store file — adopting it would mean abandoning GRDB,
rewriting all ten migrations, losing the hand-tuned FTS, and re-encoding every column.
That is explicitly out of scope and off-limits.

So: **each device keeps its own GRDB database**, and a custom sync layer moves changes
between the local DB and CloudKit. This is more code than the turnkey path, but it
preserves the entire existing stack and keeps Core testable.

### Where CloudKit sits

- **Private database** (`CKContainer.default().privateCloudDatabase`) — data is the user's,
  scoped to their iCloud account, invisible to Apple and other users.
- **One custom record zone**, `PetalZone`. A custom zone (not the default zone) is
  required to use `CKFetchRecordZoneChangesOperation` with a **server change token** (delta
  sync) and to get **atomic** multi-record saves within the zone.
- `CloudSyncService` lives in **`PetalCore/Services`** so both apps share one
  implementation. CloudKit (`import CloudKit`) is available on macOS and iOS alike.

### The seam that keeps it testable

Wrap every CloudKit operation behind a small protocol (e.g. `CloudKitBackend`) with methods
like `save(records:)`, `fetchChanges(since:)`, `delete(recordIDs:)`. `CloudSyncService`
depends on the protocol; the real implementation wraps `CKModifyRecordsOperation` /
`CKFetchRecordZoneChangesOperation`; a **fake** backend drives unit tests with no live
CloudKit. All sync *logic* (dirty selection, conflict resolution, apply-ordering, FTS
rebuild) is thus testable in `PetalCoreTests`.

---

## 2. CloudKit record schema

One `CKRecord` **recordType** per synced table. `recordName` = the row's UUID PK, so a
record's identity is stable across devices with zero coordination. All records are created
in `PetalZone`.

**Synced tables:** `paper`, `notebook`, `highlight`, `comment`, `note`, `tag`, `paper_tag`,
`page_bookmark`, `chat_session`.
**Not synced:** `search_index` (derived FTS — rebuilt locally, §4), and the `sync_state`
sidecar (device-local bookkeeping, §4).

General mapping rules:
- Scalar columns → same-named `CKRecord` fields (keep snake_case field keys to match the DB
  and avoid a translation table).
- `Date?` → `Date` fields (CloudKit native).
- JSON-encoded TEXT columns (`bounding_boxes`, `linked_highlight_ids`, chat `messages`) →
  carried as **`String`** fields verbatim; they are opaque to CloudKit and decoded only by
  the app. Do **not** try to model them as CloudKit lists.
- `note.body_rtf` (`Data?`, RTF) → **`Data`** field. It is small (a note's rich text), so it
  rides inline in the record rather than as a `CKAsset`. Only PDF files use assets.
- Foreign-key columns (`notebook_id`, `paper_id`, `highlight_id`, `parent_id`, `scope_id`) →
  store as **`String`** (the referenced UUID), **not** `CKRecord.Reference`. We manage
  referential integrity locally via GRDB FKs; CloudKit references would impose CloudKit's own
  delete semantics and ordering we don't want. Keeping them as plain strings lets us control
  apply-ordering (§4) and tombstone-based deletes (§5).

### Per-table field maps

| recordType | recordName | Fields (CKRecord ← column) |
|---|---|---|
| `paper` | `paper.id` | `notebook_id`, `title`, `authors`, `doi`, `arxiv_id`, `file_path`, `file_hash`, `page_count`, `imported_at`, `last_opened_at`, `free_space_x`, `free_space_y`, `pinned_at`, `last_page`, `last_scroll_offset`, `reading_status`, `furthest_page_read`. **PDF bytes are NOT here** — see `pdfAsset` (§3). |
| `notebook` | `notebook.id` | `name`, `parent_id`, `created_at`, `sort_order`, `ai_summary`, `ai_summary_note_count`, `ai_summary_paper_ids_hash`, `ai_summary_paper_count`, `pinned_at` |
| `highlight` | `highlight.id` | `paper_id`, `page`, `bounding_boxes` (JSON string), `color`, `selected_text`, `created_at` |
| `comment` | `comment.id` | `highlight_id`, `paper_id`, `body`, `created_at`, `updated_at` |
| `note` | `note.id` | `paper_id`, `notebook_id`, `title`, `body` (plain text), `body_rtf` (Data), `linked_highlight_ids` (JSON string), `created_at`, `updated_at` |
| `tag` | `tag.id` | `name` (see §5 for the UNIQUE-name conflict) |
| `paper_tag` | `"{paper_id}:{tag_id}"` (composite → synthetic recordName) | `paper_id`, `tag_id`. Join row, no PK of its own; the deterministic recordName means both devices generate the same record for the same pair, so re-tagging converges. |
| `page_bookmark` | `page_bookmark.id` | `paper_id`, `page` |
| `chat_session` | `chat_session.id` | `scope`, `scope_id`, `messages` (JSON string), `created_at`, `updated_at` |

Note: `page_bookmark` has no `(paper_id, page)` uniqueness in the schema; two devices could
create distinct bookmark rows for the same page. That's benign duplication — de-dupe on apply
by `(paper_id, page)` if desired (recommended, low cost).

---

## 3. PDF file sync

PDFs are the only large payload (~11 MB each in the sample library). They must not bloat the
`paper` record.

### Decision: a dedicated `pdfAsset` record carrying a `CKAsset`

- recordType **`pdfAsset`**, `recordName = paper.id` (1:1 with the paper, easy to fetch/replace
  independently of paper metadata edits).
- Fields: `file_hash` (String), `file` (`CKAsset` wrapping the PDF).
- **Upload:** on import (Mac today; mobile later), after the `paper` row is created, upload the
  `pdfAsset`. Metadata (`paper`) and bytes (`pdfAsset`) are separate records so a metadata edit
  (e.g. reading status) never re-uploads 11 MB.
- **Dedup:** the app already dedupes imports by `file_hash`. Extend that across the cloud: before
  uploading, if a `pdfAsset` with the same `file_hash` already exists, **point the paper at the
  existing asset** rather than re-uploading. (Two papers with identical bytes share one asset;
  the local `Papers/` copy is still per-paper by `file_path`.)
- **Download (mobile is lazy):** on iOS, do **not** bulk-download every PDF on first sync. Sync
  all `paper`/`highlight`/`note`/etc. metadata eagerly (small), and fetch a `pdfAsset` **on
  demand** when the user opens a paper, caching it into the device's local `Papers/`. Show a
  lightweight "downloading…" state in the reader. Optionally offer "keep offline" per paper or
  per notebook later.
- **Local cache = `Papers/` per device.** `file_path` stays **relative** to each device's
  managed `Papers/` dir (per the zero-based/relative-path conventions); it is a local cache key,
  not a synced absolute path. The synced truth of "which bytes" is `file_hash` + the asset.

CloudKit asset size is well within limits for single PDFs; the risk is *total* private-DB quota
for large libraries (§11).

---

## 4. Sync engine mechanics

### New state required — migration V11 (`V11AddSyncState`)

Add a **sidecar table**, not columns on existing tables, so no shipped model changes and no
per-model migration churn:

```
sync_state(
  entity_type   TEXT NOT NULL,   -- 'paper' | 'note' | ...
  entity_id     TEXT NOT NULL,   -- the row's UUID PK (or composite recordName for paper_tag)
  dirty         INTEGER NOT NULL DEFAULT 1,   -- 1 = local change awaiting push
  deleted       INTEGER NOT NULL DEFAULT 0,   -- 1 = tombstone (row gone locally, deletion awaiting push)
  ck_change_tag TEXT,            -- last known CKRecord.recordChangeTag from the server
  ck_system_fields BLOB,         -- archived CKRecord system fields (for correct save/merge)
  local_updated_at DATETIME,     -- monotonic local edit time, for LWW
  PRIMARY KEY (entity_type, entity_id)
)
```

Plus a tiny **`sync_cursor`** table (or a single-row key/value) holding the per-zone
**`serverChangeToken`** and the zone-created flag.

Backfill: mark every existing row `dirty = 1`, `ck_change_tag = NULL` so the first sync uploads
the current library (§9).

**How rows get marked dirty:** repositories already funnel every mutation through
`dbQueue.write`. Add sync-state upserts **inside those same transactions** (mirroring the
existing "update `search_index` in the same write" rule). A repository write → row change +
`sync_state.dirty = 1` atomically. A delete → replace the row with a `deleted = 1` tombstone in
`sync_state` in the same transaction (the row is gone from its table but remembered here until
pushed).

### Push (local → CloudKit)

1. Select `sync_state` rows where `dirty = 1 OR deleted = 1`.
2. For `deleted` rows → `CKModifyRecordsOperation.recordIDsToDelete`.
3. For `dirty` rows → build `CKRecord`s (re-hydrating archived `ck_system_fields` when present so
   the save carries the correct `recordChangeTag`), batched (CloudKit caps ~400 ops/request; page
   accordingly). PDFs go via `pdfAsset` (§3).
4. On success: clear `dirty`, store the returned `recordChangeTag`/system fields; for tombstones,
   delete the `sync_state` row entirely.
5. On `CKError.serverRecordChanged` → a conflict; resolve per §5, then retry.

### Pull (CloudKit → local)

1. `CKFetchRecordZoneChangesOperation(zone, since: serverChangeToken)`.
2. Apply changed records and deletions to GRDB **in one `dbQueue.write`**, respecting
   **foreign-key apply-ordering**: parents before children —
   `notebook` → `paper` → `highlight` → `comment`/`page_bookmark`; `tag` → `paper_tag`;
   `note` (after its `paper`/`notebook`); `chat_session` last. Deletions apply in reverse. Because
   we keep FKs as plain strings we can also defer FK enforcement within the transaction if a batch
   arrives out of order.
3. For each applied row, update `sync_state` (`ck_change_tag`, `ck_system_fields`, `dirty = 0`).
4. **Rebuild `search_index`** for touched `paper`/`note`/`comment` rows in the *same* write
   transaction (FTS has no triggers — this is the existing invariant, §CLAUDE.md). Never sync FTS.
5. Persist the new `serverChangeToken` only after the transaction commits (so a crash re-pulls
   rather than skips).

### Triggering sync

- Foreground: on app launch, on `scenePhase`/activation, and after a debounce following local
  edits (reuse the `AutosaveController` debounce idea).
- Background/near-real-time (later, §11): a `CKDatabaseSubscription` + silent push wakes the app to
  pull; `CKFetchRecordZoneChangesOperation` on receipt.

---

## 5. Conflict resolution

**Baseline policy: last-writer-wins (LWW)** per record, comparing a monotonic timestamp
(`updated_at` where the model has one, else `created_at`, else the CloudKit server-modified time).
CloudKit's `serverRecordChanged` gives us the server record; we compare and keep the newer, then
save with the server's change tag.

Table-by-table:

- **`highlight`, `comment`, `page_bookmark`** — *append-mostly, low conflict*. New rows have unique
  UUIDs and simply coexist; edits are rare. LWW is safe. `page_bookmark` duplicates de-dupe on
  `(paper_id, page)`.
- **`note` (`body_rtf`)** — **the real risk.** Field-level LWW means simultaneous edits on two
  devices lose one side's changes. v1 stance: **LWW on `updated_at`, whole-note.** Mitigations to
  document but defer: (a) since `body_rtf` is canonical and `body` derived, only merge at the RTF
  level; (b) optionally keep the losing version as a conflict-copy note (`title + " (conflict)"`)
  rather than silently discarding — recommended cheap safety net.
- **`paper` organization (`notebook_id`, `pinned_at`, `reading_status`, `free_space_*`)** — LWW.
  Reparenting/pinning conflicts resolve to the latest write; acceptable.
- **`tag`** — **UNIQUE `name` constraint is a genuine conflict.** Two devices creating "ML" offline
  produce two `tag` rows with different UUIDs but the same `name`; on sync, applying the second
  violates the local UNIQUE index. Resolution: on pull, **merge tags by name** — if an incoming
  `tag.name` already exists locally with a different id, treat the lexicographically-smaller id as
  canonical, repoint that name's `paper_tag` rows to it, and tombstone the loser. Document this as
  a required special case; it's the one place recordName-by-UUID isn't enough.
- **`paper_tag`** — deterministic recordName (`paper_id:tag_id`) means both devices converge on the
  same record; add/remove is idempotent. (Must run *after* tag-merge so the canonical tag id is
  used.)
- **`chat_session` (`messages`)** — LWW on `updated_at`. Conversations are effectively
  single-device-at-a-time; whole-record LWW is fine.

**Deletes vs edits:** tombstones (§4) win by recency too — a delete with a newer timestamp beats a
concurrent edit. Because CloudKit has **no cascade** and our FKs are local-only, a parent delete
must **explicitly tombstone its children** in the same local transaction (the app already does
cascade cleanup for e.g. paper chat rows — extend that to emit child tombstones for sync).

---

## 6. Account & identity model

- **Private CloudKit DB ⇒ single user across their own devices.** No cross-user collaboration in
  v1 (no CloudKit *shared* DB, no `CKShare`). One person, many devices, one converging library.
- **No iCloud account / signed out:** the app stays **fully functional local-only** (it is today).
  Detect account status via `CKContainer.accountStatus`; if unavailable, disable sync silently,
  keep all local edits marked `dirty`, and flush them when an account appears. Never block reading
  or annotating on iCloud.
- **API keys stay per-device in Keychain**, never in CloudKit (secrets rule). The user enters keys
  on each device; optionally rely on **iCloud Keychain** to propagate them (user-controlled, not
  our sync). Provider preference (UserDefaults) is a non-secret UI pref — may sync later via
  `NSUbiquitousKeyValueStore`, not needed for v1.
- **`chat_session` syncs** (not a secret — it's conversation content, same class as notes).

---

## 7. Core portability (make `PetalCore` build for iOS)

The library is already iOS-clean except for image encoding. Required changes (designed here,
applied in Session 37):

1. **`Services/PDFImportService.swift:83`** — the `NSBitmapImageRep` thumbnail-PNG path is AppKit.
   Replace with a cross-platform encode:
   - `#if canImport(AppKit)` → current `NSBitmapImageRep` path;
   - `#else` (iOS) → render the page to a `UIImage`/`CGImage` and PNG-encode via
     `UIImage.pngData()` or an `ImageIO`/`CGImageDestination` path (ImageIO is fully
     cross-platform and avoids the AppKit/UIKit fork entirely — **recommended**).
2. **Audit** confirms no other AppKit leaks in `Models`/`Database`/`Services` (grep already clean
   except that one file). PDFKit, CryptoKit, and Security/Keychain are all available on iOS —
   `KeychainService` works as-is (verify the `kSecClass`/access-group attributes are iOS-valid).
3. **`Package.swift`** — add `.iOS(.v16)` (or `.v17`) alongside `.macOS(.v14)` to the platforms,
   and confirm `PetalCore` builds for the iOS SDK. (Design only; do not edit this session.)
4. **SwiftMath** (used only by the macOS app target for equation rendering) stays an *app-target*
   dependency, not Core — no portability impact.

Deliverable of that later session: `swift build` for iOS Simulator compiles Core + its tests.

---

## 8. iOS / iPadOS UI plan

Full parity, **universal** (compact iPhone + regular iPad). Reuse **all** of Core untouched:
repositories, `QuickActionPrompts`, `ContextBuilder`, `ClaudeClient`/`GeminiClient`,
`KeyIdeaSuggestionService`, `TagSuggestionService`, `AIProviderPreference`. Only the presentation
layer is new.

| macOS surface | iOS plan |
|---|---|
| Library (grid/list/free-space, sidebar, search, filters) | **SwiftUI port.** Grid/list translate directly. Free-space canvas & Graph mode → iPad-friendly, deprioritize on iPhone (compact). Drag/drop uses `.draggable`/`.dropDestination` with the same `paper:`/`notebook:` payloads. |
| Notebook tree / organization / move-to menu | **SwiftUI port** (`NavigationStack`/`List` with context menus). |
| **Reader (PDFKit via `NSViewRepresentable`)** | **Rewrite as `UIViewRepresentable`** wrapping `PDFView` (PDFKit exists on iOS). Selection→highlight, tap-to-open highlight, comment popovers, thumbnail sidebar, page bookmarks, AI-notes overlay all re-implemented on touch. This is the largest single piece of new UI. Highlight geometry (`HighlightRenderer.locate`, bounding boxes) is **already portable** — same PDFKit coordinate model. |
| Notes (RTF `NSTextView`, formatting) | **Rewrite** the editor over `UITextView` + `NSAttributedString`/RTF (same `body_rtf` canonical, `body` derived rule). The RTF data is cross-platform. |
| AI chat panel (streaming, quick actions, scopes) | **SwiftUI port.** Streaming/clients are in Core; rebuild the panel view. On iPhone present as a sheet/tab; on iPad as a side column. |
| Settings (API keys, appearance, tips) | **SwiftUI port**; `KeychainService`/`AppearanceManager` reused. |
| Compare / window joining / snapping | **Mac-only → reimagine, not port.** On iPad, lean on system **Split View / Stage Manager** and (optionally later) two-scene support for side-by-side papers. On iPhone, drop. |
| Focus Mode (hides other apps/windows) | **Mac-only → drop.** iOS has no equivalent; a distraction-reduced full-screen reader is the closest analog if wanted later. |

Layout strategy: `NavigationSplitView` (sidebar / content / detail) on iPad regular width,
collapsing to a `NavigationStack` + tabs on iPhone compact width. Add sync status UI (last-synced,
downloading-PDF, offline) as a small shared component.

---

## 9. Migration & first-sync rollout

1. **Ship V11 (`V11AddSyncState`)** to the macOS app first (a normal additive migration, registered
   after `V10AddNotebookSummaryPaperSet`). It creates `sync_state`/`sync_cursor` and backfills every
   existing row `dirty = 1`.
2. **Bootstrap upload:** on first launch with sync enabled and an iCloud account, the Mac creates
   `PetalZone`, then pushes all dirty rows + `pdfAsset`s. Large libraries upload in batches;
   surface progress. This makes the **existing Mac library the CloudKit seed.**
3. **Fresh device (iPad/iPhone or a second Mac):** creates an empty DB at V11, finds the zone,
   pulls everything (metadata eager, PDFs lazy §3), rebuilds FTS locally.
4. **Idempotency:** because recordName = UUID PK, re-running bootstrap or syncing an
   already-seeded device converges (upserts, no duplicates). The `tag`-by-name and
   `page_bookmark`-by-page merges (§5) handle the pre-existing-duplicate edge.
5. **Rollback safety:** V11 only *adds* a sidecar table; disabling sync (or an older build without
   the sync layer) leaves the real data tables fully intact and usable.

---

## 10. Session roadmap

Each session is a single shippable deliverable; dependencies are strictly ordered.

| Session | Deliverable | Depends on |
|---|---|---|
| **34** | *This design doc.* | — |
| **35** | `V11AddSyncState` migration + `sync_state` writes wired into every repository transaction + `CloudKitBackend` protocol seam + `CloudSyncService` skeleton (push/pull scaffolding, no live upload). Core unit tests with a fake backend. | 34 |
| **36** | Mac push/pull **end-to-end** against real CloudKit: zone creation, `CKModifyRecordsOperation`/`CKFetchRecordZoneChangesOperation`, `pdfAsset` upload/lazy-download, change-token persistence, FTS rebuild on pull, bootstrap upload. Still **no iOS UI**; verified with two Macs or a second account. | 35 |
| **37** | iOS **target added** to the repo; Core compiles for iOS (portability §7); minimal **local reader** (open a synced paper, render PDF, download asset). Proves the phone can consume the synced store. | 36 |
| **38** | iOS **reading + highlights** UI: PDFKit `UIViewRepresentable`, selection→highlight, tap-open, comments, thumbnails, bookmarks. | 37 |
| **39** | iOS **notes + organization**: RTF editor (`UITextView`), notebook tree, library grid/list, search, filters, drag/drop. | 38 |
| **40** | iOS **AI features**: chat panel (streaming), quick actions, AI key-idea note-taking mode; reuse Core clients/prompts. | 39 |
| **41** | **Hardening**: conflict edge cases (tag-name merge, note conflict-copy), offline queueing, `CKSubscription` + silent-push background sync, sync-status UI polish, quota/large-library behavior. | 40 |

Conflict resolution and the sync engine's correctness are validated with Core unit tests
throughout (35, 36, 41) via the fake backend, so most sync logic is proven without a live CloudKit.

---

## 11. Risks & open questions

- **CloudKit quota (private DB).** Individual PDFs fit `CKAsset` limits, but a large library
  (hundreds of ~11 MB papers) can approach the user's iCloud storage. Private-DB assets count
  against the *user's* iCloud quota, not the app's — document this to users; consider a "sync PDFs:
  all / on-demand-only" setting so metadata+annotations always sync but bytes are opt-in.
- **Initial-sync time** for an existing large library — batch, show progress, make it resumable
  (dirty flags already make it resumable by construction).
- **RTF note conflicts** — the one lossy spot (§5). Recommend the conflict-copy safety net in v1.
- **`tag` UNIQUE-name merge** and **`page_bookmark` de-dupe** — the two places pure UUID identity
  isn't enough; both specified in §5, both need explicit tests.
- **Background sync** needs a `CKDatabaseSubscription` + push entitlement + `remote-notification`
  background mode; deferred to Session 41. Until then, sync is foreground/on-activation.
- **Clock skew for LWW** — device clocks can disagree. Prefer CloudKit **server change tags** as the
  ordering source where possible; treat `updated_at` as a tiebreaker, not gospel.
- **Testing without live CloudKit** — the `CloudKitBackend` fake covers logic; a small set of
  manual/integration checks against a real container (two devices) is still needed at 36 and 41.
- **Two macOS instances** — this same sync layer means a user with two Macs also converges; nothing
  iOS-specific required, a nice side effect.
- **`CURRENT_STATE.md` is stale** (says V1–V9; live is V10) — refresh it when V11 lands.

---

## Appendix A — Repository & target layout

Keep **one repository**; add the iOS app as a **new target**, not a new repo. The whole design
depends on `PetalCore` being shared *verbatim* between the apps (same models, sync schema,
conflict rules); a monorepo makes a sync-schema change a single atomic commit touching both apps,
whereas splitting Core into its own versioned package repo would force a tag-and-bump dance on
exactly the code that changes most during this work — and let the two ends' sync logic drift.

Target arrangement (SPM, and/or an Xcode workspace over the package):

```
PetalCore     (library)     Models + Database + Services   — macOS + iOS
PetalApp      (macOS exe)   App + Views (AppKit/SwiftUI)
PetalMobile   (iOS app)     iOS App + Views (UIKit/SwiftUI)   ← new
PetalCoreTests(test)        links Core only
```

`PetalMobile` depends on `PetalCore`; `SwiftMath` stays an app-target dependency.
No repo split, no submodule, no cross-repo version pinning.
