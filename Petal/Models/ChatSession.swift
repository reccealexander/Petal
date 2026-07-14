import Foundation
import GRDB

/// A persisted Claude conversation, scoped to either a paper or a notebook
/// (spec §1). `messages` is a JSON array of `{role, content, timestamp}`.
public struct ChatSession: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    /// Conversation scope. Mirrors the `scope` TEXT column: 'paper' | 'notebook'.
    public enum Scope: String, Codable {
        case paper
        case notebook
    }

    public var id: String
    public var scope: String
    public var scopeId: String
    /// JSON-encoded array of `{role, content, timestamp}` message objects.
    public var messages: String
    public var createdAt: Date
    public var updatedAt: Date?

    public init(
        id: String = UUID().uuidString,
        scope: Scope,
        scopeId: String,
        messages: String = "[]",
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.scope = scope.rawValue
        self.scopeId = scopeId
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static let databaseTableName = "chat_session"

    enum CodingKeys: String, CodingKey {
        case id
        case scope
        case scopeId = "scope_id"
        case messages
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
