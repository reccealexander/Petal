import Foundation
import GRDB

/// Owns the SQLite connection and the app's storage layout.
///
/// On disk the layout is (spec §1):
/// ```
/// ~/Library/Application Support/Petal/
///   ├── db.sqlite
///   └── Papers/            <- imported PDFs, copied on import (Session 2)
/// ```
/// Injected as a dependency (held by `AppState` in the app, constructed directly
/// in tests). `inMemory()` gives tests a fully-migrated throwaway database.
public final class DatabaseManager {
    /// Connection pool the rest of the app reads/writes through.
    public let dbQueue: DatabaseQueue

    /// Directory where imported PDF files are copied. Created on init.
    public let papersDirectory: URL

    /// Location of the on-disk database file (nil for in-memory databases).
    public let databaseURL: URL?

    // MARK: - Initialization

    /// Opens (creating if needed) the on-disk database in Application Support and
    /// ensures the `Papers/` directory exists.
    public convenience init() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = support.appendingPathComponent("Petal", isDirectory: true)
        try DatabaseManager.ensureDirectory(root)

        let papers = root.appendingPathComponent("Papers", isDirectory: true)
        try DatabaseManager.ensureDirectory(papers)

        let dbURL = root.appendingPathComponent("db.sqlite")
        let queue = try DatabaseQueue(path: dbURL.path, configuration: DatabaseManager.configuration)
        try self.init(dbQueue: queue, papersDirectory: papers, databaseURL: dbURL)
    }

    /// Designated initializer. Runs migrations against `dbQueue`.
    public init(dbQueue: DatabaseQueue, papersDirectory: URL, databaseURL: URL? = nil) throws {
        self.dbQueue = dbQueue
        self.papersDirectory = papersDirectory
        self.databaseURL = databaseURL
        try DatabaseManager.migrator.migrate(dbQueue)
    }

    /// A fully-migrated in-memory database. For tests and SwiftUI previews.
    public static func inMemory() throws -> DatabaseManager {
        let queue = try DatabaseQueue(configuration: configuration)
        let tmpPapers = FileManager.default.temporaryDirectory
            .appendingPathComponent("Petal-\(UUID().uuidString)", isDirectory: true)
        return try DatabaseManager(dbQueue: queue, papersDirectory: tmpPapers)
    }

    // MARK: - Configuration & migrations

    /// Shared GRDB configuration. Foreign keys are enabled explicitly so the
    /// cascade / set-null rules in the schema are guaranteed to fire.
    public static var configuration: Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return config
    }

    /// The migrator assembled from every registered migration, in order.
    /// Later sessions add their migrations here.
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        V1InitialSchema.register(in: &migrator)
        V2AddFileHash.register(in: &migrator)
        V3AddNotebookSummary.register(in: &migrator)
        V4AddFreeSpacePosition.register(in: &migrator)
        V5AddPinnedAt.register(in: &migrator)
        V6AddPageBookmark.register(in: &migrator)
        V7AddReadingProgress.register(in: &migrator)
        V8AddFurthestPageRead.register(in: &migrator)
        V9AddNoteRTF.register(in: &migrator)
        V10AddNotebookSummaryPaperSet.register(in: &migrator)
        V11AddSyncState.register(in: &migrator)
        return migrator
    }

    /// Identifiers of migrations that have been applied to this database.
    public func appliedMigrations() throws -> [String] {
        try dbQueue.read { db in
            try Array(DatabaseManager.migrator.appliedMigrations(db))
        }
    }

    // MARK: - Helpers

    private static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
