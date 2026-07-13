import XCTest
import GRDB
@testable import PaperReaderCore

final class NotebookSummaryServiceTests: XCTestCase {
    func testPaperSetGuardDetectsSameCountSwapButIgnoresOrdering() {
        let originalHash = NotebookSummaryService.paperSetSignature(for: ["paper-a", "paper-b"])

        XCTAssertFalse(
            NotebookSummaryService.shouldRegenerate(
                currentPaperIDs: ["paper-b", "paper-a"],
                summarizedPaperIDsHash: originalHash
            )
        )
        XCTAssertTrue(
            NotebookSummaryService.shouldRegenerate(
                currentPaperIDs: ["paper-a", "paper-c"],
                summarizedPaperIDsHash: originalHash
            ),
            "Replacing one paper with another must regenerate even when the count is unchanged"
        )
    }

    func testSummaryPaperSetMetadataPersistsAndDecodes() throws {
        let manager = try DatabaseManager.inMemory()
        let notebook = Notebook(name: "Rate-limit regression")
        try manager.dbQueue.write { db in
            try notebook.insert(db)
            try db.execute(
                sql: "UPDATE notebook SET ai_summary = ?, ai_summary_paper_ids_hash = ?, ai_summary_paper_count = ? WHERE id = ?",
                arguments: ["Cached summary", "stable-hash", 2, notebook.id]
            )
        }

        let reloaded = try manager.dbQueue.read { db in
            try Notebook.fetchOne(db, key: notebook.id)
        }

        XCTAssertEqual(reloaded?.aiSummary, "Cached summary")
        XCTAssertEqual(reloaded?.aiSummaryPaperIdsHash, "stable-hash")
        XCTAssertEqual(reloaded?.aiSummaryPaperCount, 2)
    }
}
