import Foundation

/// The transport seam between `CloudSyncService` and CloudKit. Defined over the
/// provider-neutral `SyncRecord`/`SyncRecordID` value types (not `CKRecord`) so
/// all sync *logic* is unit-testable with a fake, and so no `import CloudKit`
/// leaks into `PetalCore`. Session 36 adds the live implementation that
/// wraps `CKModifyRecordsOperation` / `CKFetchRecordZoneChangesOperation`.
public protocol CloudKitBackend: Sendable {
    /// Ensures the custom record zone exists (idempotent).
    func ensureZone() async throws

    /// Saves `records` and deletes `deletions` in one operation, returning the
    /// server-assigned change tags and any server-record-changed conflicts.
    func save(records: [SyncRecord], deletions: [SyncRecordID]) async throws -> SyncPushResult

    /// Fetches zone changes since `token` (nil = full initial fetch).
    func fetchChanges(since token: SyncChangeToken?) async throws -> SyncPullResult
}

/// A no-op backend used until the live CloudKit implementation lands (Session
/// 36) and as an inert default when sync is disabled / no iCloud account. It
/// never reports changes and echoes back deterministic change tags on save so
/// `CloudSyncService` can still clear local dirty flags in a no-cloud build.
public struct NullCloudKitBackend: CloudKitBackend {
    public init() {}

    public func ensureZone() async throws {}

    public func save(records: [SyncRecord], deletions: [SyncRecordID]) async throws -> SyncPushResult {
        var tags: [SyncRecordID: String] = [:]
        for record in records {
            tags[record.id] = record.changeTag ?? "local"
        }
        return SyncPushResult(savedChangeTags: tags, conflicts: [])
    }

    public func fetchChanges(since token: SyncChangeToken?) async throws -> SyncPullResult {
        SyncPullResult(changed: [], deleted: [], newToken: token, moreComing: false)
    }
}
