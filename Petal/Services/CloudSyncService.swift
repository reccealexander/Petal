import Foundation

/// Orchestrates one sync cycle over a `CloudKitBackend`: **pull** server changes
/// into the local GRDB store, then **push** local dirty rows and tombstones up.
/// It is an `actor` so overlapping triggers (launch, activation, post-edit
/// debounce) serialize into one cycle at a time.
///
/// This is the Session-35 skeleton: the logic (pending selection, apply,
/// last-writer-wins conflict resolution, token paging) is complete and tested
/// against a fake backend. The live CloudKit backend arrives in Session 36; no
/// change to this type is required when it does.
public actor CloudSyncService {
    private let store: SyncStateStore
    private let backend: CloudKitBackend

    public init(store: SyncStateStore, backend: CloudKitBackend) {
        self.store = store
        self.backend = backend
    }

    /// Full cycle: pull first (so local edits win over anything strictly older),
    /// then push. Returns the number of records applied and pushed.
    @discardableResult
    public func sync() async throws -> (pulled: Int, pushed: Int) {
        try await ensureZone()
        let pulled = try await pull()
        let pushed = try await push()
        return (pulled, pushed)
    }

    private func ensureZone() async throws {
        guard try store.zoneCreated() == false else { return }
        try await backend.ensureZone()
        try store.setZoneCreated(true)
    }

    /// Applies all server changes, paging through the change token until the
    /// server reports no more. Returns the count of applied records.
    @discardableResult
    public func pull() async throws -> Int {
        var applied = 0
        var token = try store.changeToken()
        while true {
            let result = try await backend.fetchChanges(since: token)
            try store.applyPulled(result)
            applied += result.changed.count + result.deleted.count
            token = result.newToken
            if !result.moreComing { break }
        }
        return applied
    }

    /// Pushes dirty rows and tombstones, resolving conflicts by last-writer-wins.
    /// Returns the number of records the server accepted.
    @discardableResult
    public func push() async throws -> Int {
        let uploads = try store.pendingUploads()
        let deletions = try store.pendingDeletions()
        guard !uploads.isEmpty || !deletions.isEmpty else { return 0 }

        let result = try await backend.save(records: uploads, deletions: deletions)
        try store.markUploaded(saved: result.savedChangeTags, deleted: deletions)

        if !result.conflicts.isEmpty {
            try await resolveConflicts(result.conflicts)
        }
        return result.savedChangeTags.count
    }

    // MARK: - Conflict resolution (last-writer-wins)

    /// For each `serverRecordChanged` conflict: if our attempt is newer, re-save
    /// it carrying the server's change tag; otherwise accept the server record
    /// and apply it locally.
    private func resolveConflicts(_ conflicts: [SyncConflict]) async throws {
        var toResave: [SyncRecord] = []
        var serverWins: [SyncRecord] = []

        for conflict in conflicts {
            if Self.isNewer(conflict.attempted, thanOrEqualTo: conflict.server) {
                var winner = conflict.attempted
                winner.changeTag = conflict.server.changeTag
                toResave.append(winner)
            } else {
                serverWins.append(conflict.server)
            }
        }

        if !serverWins.isEmpty {
            // Conflict resolution already decided the server record wins, so
            // force the apply even over the (still-dirty) local row.
            try store.applyPulled(SyncPullResult(changed: serverWins), force: true)
        }
        if !toResave.isEmpty {
            let result = try await backend.save(records: toResave, deletions: [])
            try store.markUploaded(saved: result.savedChangeTags, deleted: [])
            // A second-round conflict is left dirty for the next cycle rather than
            // looping here, so a pathological ping-pong can't stall a sync.
        }
    }

    /// Compares two records' effective modification time. Timestamps in this
    /// schema are stored as sortable TEXT, so lexical comparison is a valid
    /// ordering. Ties resolve in favor of the local record (`>=`).
    static func isNewer(_ a: SyncRecord, thanOrEqualTo b: SyncRecord) -> Bool {
        (timestamp(of: a) ?? "") >= (timestamp(of: b) ?? "")
    }

    private static let timestampFields = ["updated_at", "created_at", "imported_at", "local_updated_at"]

    private static func timestamp(of record: SyncRecord) -> String? {
        for field in timestampFields {
            if case .string(let value)? = record.fields[field] {
                return value
            }
        }
        return nil
    }
}
