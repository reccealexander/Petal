import Foundation
import GRDB

// MARK: - Provider-neutral sync value types
//
// These types are deliberately CloudKit-free so the sync *logic* and its tests
// live in `PetalCore` with no `import CloudKit`. Session 36 adds a live
// `CloudKitBackend` that translates `SyncRecord` <-> `CKRecord`; nothing in this
// file or `CloudSyncService` needs to change when it does.

/// A single column value carried across the sync boundary. Dates in this schema
/// are stored by GRDB as ISO-ish TEXT, so they round-trip as `.string` — no
/// dedicated date case is needed at this layer.
public enum SyncValue: Sendable, Equatable {
    case string(String)
    case int(Int64)
    case double(Double)
    case data(Data)
    case null

    /// Maps a GRDB column value into a `SyncValue`.
    public init(databaseValue: DatabaseValue) {
        switch databaseValue.storage {
        case .string(let s): self = .string(s)
        case .int64(let i): self = .int(i)
        case .double(let d): self = .double(d)
        case .blob(let d): self = .data(d)
        case .null: self = .null
        }
    }

    /// The GRDB-bindable representation for writing back into a row.
    public var databaseValue: DatabaseValue {
        switch self {
        case .string(let s): return s.databaseValue
        case .int(let i): return i.databaseValue
        case .double(let d): return d.databaseValue
        case .data(let d): return d.databaseValue
        case .null: return .null
        }
    }
}

/// Stable cross-device identity for one synced row. `recordType` is the entity
/// type (also the CloudKit record type); `recordName` is the row's UUID PK, or
/// for composite-key tables the `":"`-joined key values.
public struct SyncRecordID: Hashable, Sendable {
    public let recordType: String
    public let recordName: String

    public init(recordType: String, recordName: String) {
        self.recordType = recordType
        self.recordName = recordName
    }
}

/// A materialized row ready to push, or a pulled row ready to apply. `changeTag`
/// is the last-known server change tag (nil for a locally-created row not yet
/// seen by the server).
public struct SyncRecord: Sendable {
    public var id: SyncRecordID
    public var fields: [String: SyncValue]
    public var changeTag: String?

    public init(id: SyncRecordID, fields: [String: SyncValue], changeTag: String? = nil) {
        self.id = id
        self.fields = fields
        self.changeTag = changeTag
    }
}

/// Opaque per-zone delta cursor (CloudKit's `serverChangeToken`, archived).
public struct SyncChangeToken: Sendable, Equatable {
    public let data: Data
    public init(data: Data) { self.data = data }
}

/// Result of a push: the change tags the server assigned to saved records, plus
/// any records the server rejected because it holds a newer version (conflicts).
public struct SyncPushResult: Sendable {
    public var savedChangeTags: [SyncRecordID: String]
    public var conflicts: [SyncConflict]

    public init(savedChangeTags: [SyncRecordID: String] = [:], conflicts: [SyncConflict] = []) {
        self.savedChangeTags = savedChangeTags
        self.conflicts = conflicts
    }
}

/// A server-record-changed conflict: our attempted record vs. the server's
/// current record for the same id.
public struct SyncConflict: Sendable {
    public let id: SyncRecordID
    public let attempted: SyncRecord
    public let server: SyncRecord

    public init(id: SyncRecordID, attempted: SyncRecord, server: SyncRecord) {
        self.id = id
        self.attempted = attempted
        self.server = server
    }
}

/// Result of a pull: changed/added records, deleted ids, the advanced token, and
/// whether more pages remain.
public struct SyncPullResult: Sendable {
    public var changed: [SyncRecord]
    public var deleted: [SyncRecordID]
    public var newToken: SyncChangeToken?
    public var moreComing: Bool

    public init(
        changed: [SyncRecord] = [],
        deleted: [SyncRecordID] = [],
        newToken: SyncChangeToken? = nil,
        moreComing: Bool = false
    ) {
        self.changed = changed
        self.deleted = deleted
        self.newToken = newToken
        self.moreComing = moreComing
    }
}

// MARK: - Synced-entity registry

/// The tables that participate in CloudKit sync, and how each maps to a record.
/// This single list drives (a) the V11 trigger installation, (b) the initial
/// backfill, and (c) generic materialize/apply in `SyncStateStore` — so adding a
/// future synced table is a one-line change here plus a trigger in a migration.
///
/// `search_index` is intentionally absent: it is a derived FTS index, rebuilt
/// locally after each pull, never synced.
public struct SyncedEntity: Sendable {
    /// Entity type == CloudKit record type == trigger `entity_type` tag.
    public let entityType: String
    public let table: String
    /// Primary-key columns. `["id"]` for most tables; `paper_tag` is composite.
    public let keyColumns: [String]
    /// Whether applying a pulled row must refresh a `search_index` entry.
    public let searchType: SearchEntityType?

    public init(entityType: String, table: String, keyColumns: [String], searchType: SearchEntityType?) {
        self.entityType = entityType
        self.table = table
        self.keyColumns = keyColumns
        self.searchType = searchType
    }

    /// SQL expression building the record name from a trigger's `NEW`/`OLD` row,
    /// e.g. `NEW.id` or `NEW."paper_id"||':'||NEW."tag_id"`.
    public func keyExpression(alias: String) -> String {
        keyColumns
            .map { "\(alias).\"\($0)\"" }
            .joined(separator: "||':'||")
    }

    /// Splits a `recordName` back into its key-column values (single-element for
    /// UUID-keyed tables, two for `paper_tag`).
    public func keyValues(fromRecordName recordName: String) -> [String] {
        keyColumns.count == 1 ? [recordName] : recordName.components(separatedBy: ":")
    }

    /// The full registry, in foreign-key-safe apply order (parents before
    /// children). Deletions apply in reverse.
    public static let all: [SyncedEntity] = [
        SyncedEntity(entityType: "notebook", table: "notebook", keyColumns: ["id"], searchType: nil),
        SyncedEntity(entityType: "paper", table: "paper", keyColumns: ["id"], searchType: .paper),
        SyncedEntity(entityType: "tag", table: "tag", keyColumns: ["id"], searchType: nil),
        SyncedEntity(entityType: "paper_tag", table: "paper_tag", keyColumns: ["paper_id", "tag_id"], searchType: nil),
        SyncedEntity(entityType: "highlight", table: "highlight", keyColumns: ["id"], searchType: nil),
        SyncedEntity(entityType: "comment", table: "comment", keyColumns: ["id"], searchType: .comment),
        SyncedEntity(entityType: "note", table: "note", keyColumns: ["id"], searchType: .note),
        SyncedEntity(entityType: "page_bookmark", table: "page_bookmark", keyColumns: ["id"], searchType: nil),
        SyncedEntity(entityType: "chat_session", table: "chat_session", keyColumns: ["id"], searchType: nil),
    ]

    public static func lookup(_ entityType: String) -> SyncedEntity? {
        all.first { $0.entityType == entityType }
    }
}

/// A row of the `sync_state` bookkeeping table.
public struct SyncStateRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    public var entityType: String
    public var entityId: String
    public var dirty: Bool
    public var deleted: Bool
    public var ckChangeTag: String?
    public var ckSystemFields: Data?
    public var localUpdatedAt: String?

    public static let databaseTableName = "sync_state"

    enum CodingKeys: String, CodingKey {
        case entityType = "entity_type"
        case entityId = "entity_id"
        case dirty
        case deleted
        case ckChangeTag = "ck_change_tag"
        case ckSystemFields = "ck_system_fields"
        case localUpdatedAt = "local_updated_at"
    }

    public var recordID: SyncRecordID {
        SyncRecordID(recordType: entityType, recordName: entityId)
    }
}
