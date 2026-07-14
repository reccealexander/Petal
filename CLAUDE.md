# Petal Working Conventions

- Treat `CURRENT_STATE.md` and the code as current. `paper_reader_spec.md` and `session_*_prompt.md` are historical records only; do not attach them as working context.
- Keep changes compatible with Swift 6 and macOS 14+ (`Package.swift`).
- Use UUID strings for entity primary keys (`UUID().uuidString`), never autoincrement integers. `paper_tag` is the deliberate composite-key exception.
- Make schema changes with a new additive `V<n>...` migration. Never edit a shipped migration; register the new migration after the prior versions in `DatabaseManager.migrator`.
- Keep the SPM boundary intact: models, database code, repositories, and non-UI services belong in `PetalCore`; app lifecycle and SwiftUI/AppKit presentation belong in `PetalApp`. Tests link Core and must not require the `@main` executable.
- Keep database access out of view bodies. Put domain persistence in the existing repository/service layer and perform related operations in one `dbQueue.write` transaction.
- Any mutation of search-backed papers, notes, or comments must update/remove its `search_index` row in the same write transaction. FTS has no triggers or foreign keys, so cascade deletion alone is insufficient.
- Preserve snake_case database columns through each model's `CodingKeys`; keep storage encodings compatible (JSON for bounding boxes, linked highlight IDs, and chat messages; RTF `Data` for note rich text).
- For RTF-backed note writes, treat `note.body_rtf` as canonical and derive `note.body` as its plain-text FTS projection; never index RTF bytes. Be aware that the current inline `NoteEditorViewModel` is a legacy exception that writes only `body`—do not create another divergent write path.
- Reuse `AccentColorProvider` for UI that tracks the macOS system accent. Do not create another accent notification observer or hard-code an accent color.
- Reuse `AutosaveController` for debounced UI persistence; schedule on edits, flush on close, and cancel before deletion so a pending save cannot resurrect a row.
- Persist non-secret UI preferences through `AppearanceManager` using its read-in-`init`, clamp-in-`didSet`, write-to-`UserDefaults` pattern. API keys and other secrets go through `KeychainService`, in per-provider Keychain entries—never UserDefaults or plaintext.
- Route provider-switchable AI work through `AIProviderPreference.effectiveProvider` and the provider-neutral call site. Keep provider selection in UserDefaults and keys in Keychain. Tag suggestions are the current intentional Gemini-only exception.
- Use `paper:<id>` and `notebook:<id>` for library drag payloads; parse the prefix rather than inventing a second payload format.
- Preserve zero-based page indexes in persistence and reader APIs; add one only for user-facing page labels/progress counts.
- Use repositories as the persistence source of truth for PDF annotations. Rehydrate PDFKit annotations from stored highlights/comments instead of treating `PDFAnnotation` instances as durable state.
- When adding a joinable window, register a stable `JoinablePaneRef` with `WindowSnapController`, unregister it on disappearance, and support reopening through the joined window's split-out path.
- Keep prompt templates centralized in `QuickActionPrompts.swift`; rebuild paper/notebook context through `ContextBuilder` so current highlights, comments, and notes are included.
