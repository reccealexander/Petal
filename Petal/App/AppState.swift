import Foundation
import OSLog
import SwiftUI
import PetalCore
import GRDB

/// Global, observable app state (spec §2): the selected notebook, the open paper,
/// Claude-panel visibility, and the shared database dependency.
///
/// For Session 1 the UI state fields are placeholders — nothing drives them yet —
/// but they establish the shape later sessions plug into. The database is created
/// and migrated here on launch, and its status is surfaced to the UI.
@MainActor
final class AppState: ObservableObject {
    private static let logger = Logger(subsystem: "com.paperreader.app", category: "database")

    // MARK: - UI state (populated in later sessions)

    @Published var selectedNotebookId: String?
    @Published var openPaperId: String?
    @Published var isClaudePanelVisible: Bool = false

    // MARK: - Database

    @Published private(set) var databaseStatus: DatabaseStatus = .initializing

    /// The shared database dependency. Injected into views via `AppState`.
    private(set) var database: DatabaseManager?

    // MARK: - Papers / import

    @Published private(set) var papers: [Paper] = []
    private(set) var importService: PDFImportService?
    @Published var importMessage: String?

    enum DatabaseStatus {
        case initializing
        case ready(migrations: [String], path: String)
        case failed(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    init() {
        bootstrapDatabase()
    }

    /// Creates/opens and migrates the database, updating `databaseStatus` and
    /// logging a confirmation so launch success is verifiable (spec Session 1 §7).
    func bootstrapDatabase() {
        do {
            let db = try DatabaseManager()
            self.database = db
            self.importService = PDFImportService(database: db)
            self.reloadPapers()

            let applied = try db.appliedMigrations()
            let path = db.databaseURL?.path ?? "(in-memory)"
            self.databaseStatus = .ready(migrations: applied, path: path)

            Self.logger.info(
                "Database ready at \(path, privacy: .public) — applied migrations: \(applied.joined(separator: ", "), privacy: .public)"
            )
            print("✅ Petal DB initialized at \(path)")
            print("   Applied migrations: \(applied.joined(separator: ", "))")
            print("   PDF store: \(db.papersDirectory.path)")
        } catch {
            self.databaseStatus = .failed(String(describing: error))
            Self.logger.error("Database initialization failed: \(String(describing: error), privacy: .public)")
            print("❌ Petal DB initialization failed: \(error)")
        }
    }

    /// Reloads the papers list from the database, newest import first.
    func reloadPapers() {
        guard let db = database else { papers = []; return }
        papers = (try? db.dbQueue.read { try Paper.fetchAll($0, sql: "SELECT * FROM paper ORDER BY imported_at DESC") }) ?? []
    }

    /// Imports each PDF at `urls`, surfacing a duplicate/error message via `importMessage`.
    func importPapers(from urls: [URL]) {
        guard let importService else { return }
        var duplicateTitle: String?
        for url in urls {
            do {
                switch try importService.importPDF(from: url) {
                case .imported:
                    break
                case .duplicate(let existing):
                    duplicateTitle = existing.title ?? "This paper"
                }
            } catch {
                importMessage = "Import failed: \(error.localizedDescription)"
            }
        }
        reloadPapers()
        if let duplicateTitle {
            importMessage = "“\(duplicateTitle)” is already imported."
        }
    }
}
