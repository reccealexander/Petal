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

/// Persists the ongoing Claude conversation for a given scope (paper or
/// notebook) as a single `ChatSession` row. Only one conversation per
/// scope/scopeId pair is supported for now — later sessions may add
/// multi-conversation support.
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

    /// Loads the persisted conversation for `scope`/`scopeId`, or `[]` if no
    /// session row exists yet.
    public func loadMessages(scope: ChatSession.Scope, scopeId: String) -> [ChatMessage] {
        let row = try? dbQueue.read { db in
            try ChatSession.fetchOne(
                db,
                sql: "SELECT * FROM chat_session WHERE scope = ? AND scope_id = ? ORDER BY created_at LIMIT 1",
                arguments: [scope.rawValue, scopeId]
            )
        }
        guard let session = row ?? nil else { return [] }
        return Self.decode(session.messages)
    }

    /// Persists `messages` for `scope`/`scopeId` — updating the existing row
    /// if one exists, else inserting a new `ChatSession`.
    public func saveMessages(_ messages: [ChatMessage], scope: ChatSession.Scope, scopeId: String) throws {
        let json = Self.encode(messages)
        try dbQueue.write { db in
            if var existing = try ChatSession.fetchOne(
                db,
                sql: "SELECT * FROM chat_session WHERE scope = ? AND scope_id = ? ORDER BY created_at LIMIT 1",
                arguments: [scope.rawValue, scopeId]
            ) {
                existing.messages = json
                existing.updatedAt = Date()
                try existing.update(db)
            } else {
                let session = ChatSession(scope: scope, scopeId: scopeId, messages: json)
                try session.insert(db)
            }
        }
    }
}
