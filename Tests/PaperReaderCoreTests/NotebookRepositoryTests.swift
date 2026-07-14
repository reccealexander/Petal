import XCTest
import GRDB
@testable import PaperReaderCore

/// Exercises `NotebookRepository`'s public API: recursive descendant queries,
/// cycle-safe reparenting, cascade delete with paper orphaning, and the
/// paper<->notebook move helpers.
final class NotebookRepositoryTests: XCTestCase {
    private var manager: DatabaseManager!
    private var repo: NotebookRepository!

    override func setUpWithError() throws {
        manager = try DatabaseManager.inMemory()
        repo = NotebookRepository(database: manager)
    }

    override func tearDownWithError() throws {
        manager = nil
        repo = nil
    }

    // MARK: - Helpers

    private func insertPaper(notebookId: String? = nil) throws -> Paper {
        let paper = Paper(notebookId: notebookId, filePath: "\(UUID().uuidString).pdf")
        try manager.dbQueue.write { try paper.insert($0) }
        return paper
    }

    // MARK: - Tests

    func testPapersUnderIncludesDescendants() throws {
        let research = try repo.create(name: "Research", parentId: nil)
        let sub = try repo.create(name: "Sub", parentId: research.id)
        let deep = try repo.create(name: "Deep", parentId: sub.id)

        let paperInSub = try insertPaper(notebookId: sub.id)
        let paperInDeep = try insertPaper(notebookId: deep.id)
        let unfiledPaper = try insertPaper(notebookId: nil)

        let papers = try repo.papersUnder(notebookId: research.id)
        let ids = Set(papers.map(\.id))

        XCTAssertEqual(ids, Set([paperInSub.id, paperInDeep.id]))
        XCTAssertFalse(ids.contains(unfiledPaper.id))
    }

    func testMoveRejectsCycle() throws {
        let a = try repo.create(name: "A", parentId: nil)
        let b = try repo.create(name: "B", parentId: a.id)

        XCTAssertThrowsError(try repo.move(id: a.id, toParent: b.id)) { error in
            guard case NotebookError.wouldCreateCycle = error else {
                XCTFail("Expected NotebookError.wouldCreateCycle, got \(error)")
                return
            }
        }
    }

    func testMoveValidReparent() throws {
        let a = try repo.create(name: "A", parentId: nil)
        let b = try repo.create(name: "B", parentId: nil)

        try repo.move(id: b.id, toParent: a.id)

        let all = try repo.allNotebooks()
        let reloadedB = try XCTUnwrap(all.first { $0.id == b.id })
        XCTAssertEqual(reloadedB.parentId, a.id)
    }

    func testDeleteCascadesSubtreeAndOrphansPapers() throws {
        let parent = try repo.create(name: "Parent", parentId: nil)
        let child = try repo.create(name: "Child", parentId: parent.id)
        let paper = try insertPaper(notebookId: child.id)

        try repo.delete(id: parent.id)

        let remaining = try repo.allNotebooks()
        XCTAssertTrue(remaining.isEmpty)

        let fetchedPaper = try manager.dbQueue.read { db in
            try Paper.fetchOne(db, key: paper.id)
        }
        let unwrapped = try XCTUnwrap(fetchedPaper)
        XCTAssertNil(unwrapped.notebookId)
    }

    func testRecentlyViewedPapersOrdersByLastOpenedDescAndCaps() throws {
        // Never-opened papers are excluded.
        _ = try insertPaper(notebookId: nil)

        let base = Date(timeIntervalSince1970: 1_000_000)
        var opened: [(id: String, date: Date)] = []
        for offset in 0..<12 {
            let date = base.addingTimeInterval(Double(offset) * 60)
            let paper = Paper(filePath: "\(UUID().uuidString).pdf", lastOpenedAt: date)
            try manager.dbQueue.write { try paper.insert($0) }
            opened.append((paper.id, date))
        }

        let recent = try repo.recentlyViewedPapers(limit: 10)

        // Capped at 10, most-recent first, and only opened papers included.
        XCTAssertEqual(recent.count, 10)
        let expected = opened.sorted { $0.date > $1.date }.prefix(10).map(\.id)
        XCTAssertEqual(recent.map(\.id), Array(expected))
    }

    func testRecentlyViewedPapersEmptyWhenNoneOpened() throws {
        _ = try insertPaper(notebookId: nil)
        XCTAssertTrue(try repo.recentlyViewedPapers().isEmpty)
    }

    func testMovePaperAndContainsPapers() throws {
        let nb = try repo.create(name: "Notebook", parentId: nil)
        let paper = try insertPaper(notebookId: nil)

        XCTAssertFalse(try repo.containsPapers(notebookId: nb.id))

        try repo.movePaper(paperId: paper.id, toNotebook: nb.id)

        XCTAssertTrue(try repo.containsPapers(notebookId: nb.id))
        let papers = try repo.papersUnder(notebookId: nb.id)
        XCTAssertTrue(papers.contains { $0.id == paper.id })
    }
}
