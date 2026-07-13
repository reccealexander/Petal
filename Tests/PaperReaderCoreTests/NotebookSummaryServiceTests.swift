import XCTest
import GRDB
@testable import PaperReaderCore

final class NotebookSummaryServiceTests: XCTestCase {
    func testCountGuardRegeneratesOnlyAfterGenuineNoteIncrease() {
        XCTAssertFalse(
            NotebookSummaryService.shouldRegenerate(
                currentNoteCount: 3,
                summarizedNoteCount: 3
            ),
            "Editing or autosaving existing notes must not regenerate a summary"
        )
        XCTAssertFalse(
            NotebookSummaryService.shouldRegenerate(
                currentNoteCount: 2,
                summarizedNoteCount: 3
            ),
            "Deleting a note must not regenerate a summary"
        )
        XCTAssertTrue(
            NotebookSummaryService.shouldRegenerate(
                currentNoteCount: 4,
                summarizedNoteCount: 3
            ),
            "A newly inserted note must cross the persisted count guard"
        )
    }

    func testSummaryNoteCountPersistsAndDecodesFromNotebookColumn() throws {
        let manager = try DatabaseManager.inMemory()
        let notebook = Notebook(name: "Rate-limit regression")
        try manager.dbQueue.write { db in
            try notebook.insert(db)
            try db.execute(
                sql: "UPDATE notebook SET ai_summary = ?, ai_summary_note_count = ? WHERE id = ?",
                arguments: ["Cached summary", 7, notebook.id]
            )
        }

        let reloaded = try manager.dbQueue.read { db in
            try Notebook.fetchOne(db, key: notebook.id)
        }

        XCTAssertEqual(reloaded?.aiSummary, "Cached summary")
        XCTAssertEqual(reloaded?.aiSummaryNoteCount, 7)
    }
}
