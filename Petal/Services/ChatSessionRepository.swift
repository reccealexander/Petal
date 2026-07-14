import Foundation
import GRDB

/// A single message in a paper- or notebook-scoped Claude conversation.
/// Persisted as JSON (an array of these) in `ChatSession.messages`.
public struct ChatMessage: Codable, Identifiable, Hashable {
    public let id: UUID
    /// `"user"` or `"assistant"`.
    public var role: String
    public var content: String
    public var timestamp: Date

    public init(id: UUID = UUID(), role: String, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

/// Persists Claude conversations for paper and notebook scopes. A scope may
/// own any number of sessions; individual conversations are loaded, saved,
/// and deleted by their stable `ChatSession.id`.
public final class ChatSessionRepository {
    private let dbQueue: DatabaseQueue

    public init(database: DatabaseManager) {
        self.dbQueue = database.dbQueue
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Encodes `messages` to a JSON string suitable for `ChatSession.messages`.
    /// Returns `"[]"` if encoding fails.
    public static func encode(_ messages: [ChatMessage]) -> String {
        guard let data = try? encoder.encode(messages),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    /// Decodes a `ChatSession.messages` JSON string. Returns `[]` on any
    /// decode failure (e.g. no row yet, or malformed JSON).
    public static func decode(_ json: String) -> [ChatMessage] {
        guard let data = json.data(using: .utf8),
              let messages = try? decoder.decode([ChatMessage].self, from: data) else {
            return []
        }
        return messages
    }

    /// All conversations for a scope, with the most recently active first.
    public func sessions(scope: ChatSession.Scope, scopeId: String) -> [ChatSession] {
        (try? dbQueue.read { db in
            try ChatSession.fetchAll(
                db,
                sql: """
                    SELECT * FROM chat_session
                    WHERE scope = ? AND scope_id = ?
                    ORDER BY (updated_at IS NULL), updated_at DESC, created_at DESC, rowid DESC
                    """,
                arguments: [scope.rawValue, scopeId]
            )
        }) ?? []
    }

    /// The most recently active conversation for a scope, if one exists.
    public func mostRecentSession(scope: ChatSession.Scope, scopeId: String) -> ChatSession? {
        try? dbQueue.read { db in
            try ChatSession.fetchOne(
                db,
                sql: """
                    SELECT * FROM chat_session
                    WHERE scope = ? AND scope_id = ?
                    ORDER BY (updated_at IS NULL), updated_at DESC, created_at DESC, rowid DESC
                    LIMIT 1
                    """,
                arguments: [scope.rawValue, scopeId]
            )
        }
    }

    /// Loads and decodes one conversation by its session id.
    public func messages(inSessionId id: String) -> [ChatMessage] {
        let json = try? dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT messages FROM chat_session WHERE id = ?",
                arguments: [id]
            )
        }
        guard let json = json ?? nil else { return [] }
        return Self.decode(json)
    }

    /// Updates one conversation by id and marks it as recently active.
    public func saveMessages(_ messages: [ChatMessage], inSessionId id: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE chat_session SET messages = ?, updated_at = ? WHERE id = ?",
                arguments: [Self.encode(messages), Date(), id]
            )
        }
    }

    /// Creates a new empty conversation. Giving it an `updatedAt` makes the
    /// newly-created session the most recent even before its first message.
    public func createSession(scope: ChatSession.Scope, scopeId: String) throws -> ChatSession {
        let session = ChatSession(scope: scope, scopeId: scopeId, updatedAt: Date())
        try dbQueue.write { db in
            try session.insert(db)
        }
        return session
    }

    /// Deletes only the requested chat row. `chat_session` has no foreign-key
    /// relationships, so this cannot cascade into highlights, comments, notes,
    /// papers, or notebooks.
    public func deleteSession(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM chat_session WHERE id = ?", arguments: [id])
        }
    }

    /// Loads the persisted conversation for `scope`/`scopeId`, or `[]` if no
    /// session row exists yet.
    public func loadMessages(scope: ChatSession.Scope, scopeId: String) -> [ChatMessage] {
        guard let session = mostRecentSession(scope: scope, scopeId: scopeId) else { return [] }
        return messages(inSessionId: session.id)
    }

    /// Persists `messages` for `scope`/`scopeId` — updating the existing row
    /// if one exists, else inserting a new `ChatSession`.
    public func saveMessages(_ messages: [ChatMessage], scope: ChatSession.Scope, scopeId: String) throws {
        let session = try mostRecentSession(scope: scope, scopeId: scopeId)
            ?? createSession(scope: scope, scopeId: scopeId)
        try saveMessages(messages, inSessionId: session.id)
    }
}
