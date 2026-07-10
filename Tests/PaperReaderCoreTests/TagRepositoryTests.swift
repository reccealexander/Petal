import XCTest
import GRDB
@testable import PaperReaderCore

/// Exercises `TagRepository`'s public API: name-deduped tag creation,
/// assignment to papers, and the paper<->tag listing helpers.
final class TagRepositoryTests: XCTestCase {
    private var manager: DatabaseManager!
    private var repo: TagRepository!

    override func setUpWithError() throws {
        manager = try DatabaseManager.inMemory()
        repo = TagRepository(database: manager)
    }

    override func tearDownWithError() throws {
        manager = nil
        repo = nil
    }

    // MARK: - Helpers

    private func insertPaper() throws -> Paper {
        let paper = Paper(filePath: "\(UUID().uuidString).pdf")
        try manager.dbQueue.write { try paper.insert($0) }
        return paper
    }

    // MARK: - Tests

    func testCreateTagDedupesByName() throws {
        let first = try repo.createTag(name: "swift")
        let second = try repo.createTag(name: "swift")

        XCTAssertEqual(first.id, second.id)

        let all = try repo.allTags()
        XCTAssertEqual(all.count, 1)
    }

    func testAddTagAssignsAndListsForPaper() throws {
        let paper = try insertPaper()

        try repo.addTag(name: "ml", toPaper: paper.id)

        let tagsForPaper = try repo.tags(forPaper: paper.id)
        XCTAssertTrue(tagsForPaper.contains { $0.name == "ml" })

        let tag = try XCTUnwrap(tagsForPaper.first { $0.name == "ml" })
        let paperIds = try repo.paperIds(withTag: tag.id)
        XCTAssertTrue(paperIds.contains(paper.id))
    }

    func testRemoveTagFromPaperKeepsTag() throws {
        let paper = try insertPaper()
        let tag = try repo.addTag(name: "ml", toPaper: paper.id)

        try repo.removeTag(tagId: tag.id, fromPaper: paper.id)

        let tagsForPaper = try repo.tags(forPaper: paper.id)
        XCTAssertTrue(tagsForPaper.isEmpty)

        let all = try repo.allTags()
        XCTAssertTrue(all.contains { $0.id == tag.id })
    }

    func testDeleteTagRemovesTagAndAssociations() throws {
        let paper = try insertPaper()
        let tag = try repo.addTag(name: "obsolete", toPaper: paper.id)

        XCTAssertTrue(try repo.allTags().contains { $0.id == tag.id })
        XCTAssertTrue(try repo.tags(forPaper: paper.id).contains { $0.id == tag.id })

        try repo.deleteTag(id: tag.id)

        XCTAssertTrue(try repo.allTags().isEmpty)
        XCTAssertTrue(try repo.tags(forPaper: paper.id).isEmpty)

        let stillThere = try manager.dbQueue.read { db in
            try Paper.fetchOne(db, key: paper.id)
        }
        XCTAssertNotNil(stillThere)
    }
}
