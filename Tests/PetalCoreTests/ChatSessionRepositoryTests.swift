import XCTest
import GRDB
@testable import PetalCore

final class ChatSessionRepositoryTests: XCTestCase {
    private var manager: DatabaseManager!
    private var repository: ChatSessionRepository!

    override func setUpWithError() throws {
        manager = try DatabaseManager.inMemory()
        repository = ChatSessionRepository(database: manager)
    }

    override func tearDownWithError() throws {
        repository = nil
        manager = nil
    }

    func testCreateListLoadAndDeleteOneSessionWithoutDeletingPaperData() throws {
        let paper = Paper(filePath: "sessions.pdf")
        let highlight = Highlight(
            paperId: paper.id,
            page: 0,
            boundingBoxes: "[]",
            selectedText: "important passage"
        )
        let comment = Comment(highlightId: highlight.id, paperId: paper.id, body: "keep this")
        let note = Note(paperId: paper.id, title: "Notes", body: "keep this too")
        try manager.dbQueue.write { db in
            try paper.insert(db)
            try highlight.insert(db)
            try comment.insert(db)
            try note.insert(db)
        }

        let first = try repository.createSession(scope: .paper, scopeId: paper.id)
        let firstMessages = [ChatMessage(role: "user", content: "First conversation")]
        try repository.saveMessages(firstMessages, inSessionId: first.id)
        let second = try repository.createSession(scope: .paper, scopeId: paper.id)
        let notebookSession = try repository.createSession(scope: .notebook, scopeId: "notebook-1")

        let paperSessions = repository.sessions(scope: .paper, scopeId: paper.id)
        XCTAssertEqual(paperSessions.map(\.id), [second.id, first.id])
        XCTAssertEqual(repository.mostRecentSession(scope: .paper, scopeId: paper.id)?.id, second.id)
        let loadedMessages = repository.messages(inSessionId: first.id)
        XCTAssertEqual(loadedMessages.map(\.id), firstMessages.map(\.id))
        XCTAssertEqual(loadedMessages.map(\.role), ["user"])
        XCTAssertEqual(loadedMessages.map(\.content), ["First conversation"])
        XCTAssertEqual(repository.messages(inSessionId: second.id), [])

        try repository.deleteSession(id: first.id)

        XCTAssertEqual(repository.sessions(scope: .paper, scopeId: paper.id).map(\.id), [second.id])
        XCTAssertEqual(repository.sessions(scope: .notebook, scopeId: "notebook-1").map(\.id), [notebookSession.id])
        XCTAssertEqual(repository.messages(inSessionId: first.id), [])

        try manager.dbQueue.read { db in
            XCTAssertEqual(try Paper.fetchCount(db), 1)
            XCTAssertEqual(try Highlight.fetchCount(db), 1)
            XCTAssertEqual(try Comment.fetchCount(db), 1)
            XCTAssertEqual(try Note.fetchCount(db), 1)
            XCTAssertEqual(try ChatSession.fetchCount(db), 2)
        }
    }
}
