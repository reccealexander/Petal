import XCTest
import GRDB
@testable import PetalCore

/// Adversarial edge-case coverage for the repository layer. Every test in this
/// file passes against *current* behavior — it pins ordering, tiebreaks, null
/// handling, cascade + FTS maintenance, cycle-safe moves, and dedupe so that a
/// future regression (or an intentional fix to one of the documented quirks)
/// shows up as a failure. Known REAL bugs are documented in the accompanying
/// report, not asserted-as-correct here.
final class RepositoryEdgeCaseTests: XCTestCase {
    private var manager: DatabaseManager!

    override func setUpWithError() throws {
        manager = try DatabaseManager.inMemory()
    }

    override func tearDownWithError() throws {
        manager = nil
    }

    // MARK: - Fixtures

    @discardableResult
    private func insertPaper(
        id: String = UUID().uuidString,
        notebookId: String? = nil,
        title: String? = "Paper",
        lastOpenedAt: Date? = nil,
        importedAt: Date = Date()
    ) throws -> Paper {
        let paper = Paper(
            id: id,
            notebookId: notebookId,
            title: title,
            filePath: "\(id).pdf",
            importedAt: importedAt,
            lastOpenedAt: lastOpenedAt
        )
        try manager.dbQueue.write { db in try paper.insert(db) }
        return paper
    }

    // MARK: - NoteRepository: body vs body_rtf, FTS projection, primary note

    func testLoadOrCreatePrimaryNoteIsIdempotentAndReturnsEarliestCreated() throws {
        let repo = NoteRepository(database: manager)
        let paper = try insertPaper()

        // Seed two notes with distinct created_at; the earlier one is "primary".
        let early = Note(paperId: paper.id, title: "early", body: "e",
                         createdAt: Date(timeIntervalSince1970: 1_000))
        let late = Note(paperId: paper.id, title: "late", body: "l",
                        createdAt: Date(timeIntervalSince1970: 2_000))
        try manager.dbQueue.write { db in
            try early.insert(db)
            try late.insert(db)
        }

        let primary = try repo.loadOrCreatePrimaryNote(forPaper: paper.id, title: "x")
        XCTAssertEqual(primary.id, early.id, "primary note must be earliest-created")

        // No new row created when one already exists.
        try manager.dbQueue.read { db in
            XCTAssertEqual(try Note.filter(Column("paper_id") == paper.id).fetchCount(db), 2)
        }
    }

    func testCreateNoteFullyUnlinkedIsIndexedForSearch() throws {
        let repo = NoteRepository(database: manager)
        let note = try repo.createNote(paperId: nil, notebookId: nil, title: nil)
        XCTAssertNil(note.paperId)
        XCTAssertNil(note.notebookId)

        // Empty-body note produces an (empty-content) index row that still exists.
        try manager.dbQueue.read { db in
            let count = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM search_index WHERE entity_id = ?",
                arguments: [note.id]
            )
            XCTAssertEqual(count, 1)
        }
    }

    func testSaveIndexesPlainBodyNotRtfBytes() throws {
        // Documents the contract: `body` is the FTS projection; `body_rtf` is
        // canonical storage but is NEVER indexed. A caller that updates only
        // `body` (the legacy inline-editor path) still yields a correct index.
        let repo = NoteRepository(database: manager)
        let search = SearchRepository(database: manager)
        var note = try repo.createNote(paperId: nil, notebookId: nil, title: "t")

        note.body = "photosynthesis chloroplast"
        note.bodyRtf = Data("{\\rtf1 RTFONLYWORD zzqqx }".utf8)
        try repo.save(note)

        // Searchable by the plain-text body...
        XCTAssertEqual(try search.search("photosynthesis").map(\.id), [note.id])
        // ...but never by tokens that exist only inside the RTF bytes.
        XCTAssertTrue(try search.search("RTFONLYWORD").isEmpty)
        XCTAssertTrue(try search.search("zzqqx").isEmpty)
    }

    func testSaveStampsUpdatedAt() throws {
        let repo = NoteRepository(database: manager)
        var note = try repo.createNote(paperId: nil, notebookId: nil, title: "t")
        XCTAssertNil(note.updatedAt, "freshly created note has no updated_at")
        note.body = "changed"
        try repo.save(note)
        let reloaded = try XCTUnwrap(repo.note(id: note.id))
        XCTAssertNotNil(reloaded.updatedAt, "save must stamp updated_at")
    }

    func testDeleteNoteRemovesSearchIndexRow() throws {
        let repo = NoteRepository(database: manager)
        let search = SearchRepository(database: manager)
        var note = try repo.createNote(paperId: nil, notebookId: nil, title: "t")
        note.body = "neutrino oscillation"
        try repo.save(note)
        XCTAssertFalse(try search.search("neutrino").isEmpty)

        try repo.deleteNote(id: note.id)
        XCTAssertTrue(try search.search("neutrino").isEmpty, "delete must purge the FTS row")
        try manager.dbQueue.read { db in
            XCTAssertEqual(try Note.fetchCount(db), 0)
        }
    }

    // MARK: - TagRepository: find-or-create, trimming, case sensitivity, cascade

    func testFindOrCreateTagTrimsAndDedupesOnExactName() throws {
        let repo = TagRepository(database: manager)
        let a = try repo.createTag(name: "  machine learning  ")
        let b = try repo.createTag(name: "machine learning")
        XCTAssertEqual(a.id, b.id, "trimmed names must resolve to the same tag")
        XCTAssertEqual(try repo.allTags().count, 1)
    }

    func testFindOrCreateTagIsCaseInsensitive() throws {
        // "AI" and "ai" resolve to one tag (case-insensitive find-or-create), so
        // a single concept isn't fragmented into duplicate rows.
        let repo = TagRepository(database: manager)
        let upper = try repo.createTag(name: "AI")
        let lower = try repo.createTag(name: "ai")
        XCTAssertEqual(upper.id, lower.id)
        XCTAssertEqual(try repo.allTags().count, 1)
    }

    func testBlankTagNameIsRejected() throws {
        let repo = TagRepository(database: manager)
        XCTAssertThrowsError(try repo.createTag(name: "   ")) { error in
            XCTAssertEqual(error as? TagError, .blankName)
        }
        XCTAssertTrue(try repo.allTags().isEmpty)
    }

    func testAddTagDedupesPaperAssignment() throws {
        let repo = TagRepository(database: manager)
        let paper = try insertPaper()
        let t1 = try repo.addTag(name: "graphs", toPaper: paper.id)
        let t2 = try repo.addTag(name: "graphs", toPaper: paper.id)
        XCTAssertEqual(t1.id, t2.id)
        XCTAssertEqual(try repo.tags(forPaper: paper.id).count, 1, "duplicate assignment is ignored")
    }

    func testDeleteTagCascadesPaperAssociations() throws {
        let repo = TagRepository(database: manager)
        let paper = try insertPaper()
        let tag = try repo.addTag(name: "physics", toPaper: paper.id)
        XCTAssertEqual(try repo.paperIds(withTag: tag.id), [paper.id])

        try repo.deleteTag(id: tag.id)
        XCTAssertTrue(try repo.tags(forPaper: paper.id).isEmpty)
        try manager.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM paper_tag"), 0)
        }
    }

    // MARK: - ChatSessionRepository: recency ordering & tiebreaks

    func testSessionOrderingUpdatedAtDescThenNullLast() throws {
        let repo = ChatSessionRepository(database: manager)
        let scopeId = "paper-1"
        let newer = ChatSession(scope: .paper, scopeId: scopeId,
                                createdAt: Date(timeIntervalSince1970: 10),
                                updatedAt: Date(timeIntervalSince1970: 500))
        let older = ChatSession(scope: .paper, scopeId: scopeId,
                                createdAt: Date(timeIntervalSince1970: 20),
                                updatedAt: Date(timeIntervalSince1970: 100))
        let neverUpdated = ChatSession(scope: .paper, scopeId: scopeId,
                                       createdAt: Date(timeIntervalSince1970: 30),
                                       updatedAt: nil)
        try manager.dbQueue.write { db in
            try older.insert(db)
            try neverUpdated.insert(db)
            try newer.insert(db)
        }
        XCTAssertEqual(repo.sessions(scope: .paper, scopeId: scopeId).map(\.id),
                       [newer.id, older.id, neverUpdated.id],
                       "updated_at DESC, NULLs last")
        XCTAssertEqual(repo.mostRecentSession(scope: .paper, scopeId: scopeId)?.id, newer.id)
    }

    func testSessionTiebreakFallsBackToCreatedAtThenRowid() throws {
        let repo = ChatSessionRepository(database: manager)
        let scopeId = "paper-tie"
        let sameUpdated = Date(timeIntervalSince1970: 900)

        // Same updated_at, different created_at -> created_at DESC wins.
        let earlierCreated = ChatSession(scope: .paper, scopeId: scopeId,
                                         createdAt: Date(timeIntervalSince1970: 1),
                                         updatedAt: sameUpdated)
        let laterCreated = ChatSession(scope: .paper, scopeId: scopeId,
                                       createdAt: Date(timeIntervalSince1970: 2),
                                       updatedAt: sameUpdated)
        // Fully identical updated_at AND created_at -> rowid DESC (insertion) wins.
        let sameStamp = Date(timeIntervalSince1970: 5)
        let firstInserted = ChatSession(scope: .paper, scopeId: scopeId,
                                        createdAt: sameStamp, updatedAt: sameStamp)
        let secondInserted = ChatSession(scope: .paper, scopeId: scopeId,
                                         createdAt: sameStamp, updatedAt: sameStamp)
        try manager.dbQueue.write { db in
            try earlierCreated.insert(db)
            try laterCreated.insert(db)
            try firstInserted.insert(db)
            try secondInserted.insert(db)
        }

        let ordered = repo.sessions(scope: .paper, scopeId: scopeId).map(\.id)
        // sameUpdated (900) is the most recent updated_at overall.
        XCTAssertEqual(Array(ordered.prefix(2)), [laterCreated.id, earlierCreated.id],
                       "equal updated_at falls back to created_at DESC")
        XCTAssertEqual(Array(ordered.suffix(2)), [secondInserted.id, firstInserted.id],
                       "fully-equal timestamps fall back to rowid DESC")
    }

    func testSaveMessagesReusesMostRecentSession() throws {
        let repo = ChatSessionRepository(database: manager)
        try repo.saveMessages([ChatMessage(role: "user", content: "hi")],
                              scope: .notebook, scopeId: "nb")
        try repo.saveMessages([ChatMessage(role: "user", content: "again")],
                              scope: .notebook, scopeId: "nb")
        // Both writes target the same (only) session — no duplicate rows.
        XCTAssertEqual(repo.sessions(scope: .notebook, scopeId: "nb").count, 1)
        XCTAssertEqual(repo.loadMessages(scope: .notebook, scopeId: "nb").map(\.content), ["again"])
    }

    // MARK: - NotebookRepository: cycle-safe move

    func testMoveUnderOwnDescendantThrowsCycle() throws {
        let repo = NotebookRepository(database: manager)
        let root = try repo.create(name: "root", parentId: nil)
        let child = try repo.create(name: "child", parentId: root.id)
        let grandchild = try repo.create(name: "grandchild", parentId: child.id)

        XCTAssertThrowsError(try repo.move(id: root.id, toParent: grandchild.id)) { error in
            XCTAssertEqual(error as? NotebookError, .wouldCreateCycle)
        }
        XCTAssertThrowsError(try repo.move(id: root.id, toParent: root.id)) { error in
            XCTAssertEqual(error as? NotebookError, .wouldCreateCycle)
        }
        // Structure unchanged after a rejected move.
        XCTAssertEqual(try repo.notebook(id: root.id)?.parentId, nil)
    }

    func testMoveToUnrelatedParentAndToRootSucceeds() throws {
        let repo = NotebookRepository(database: manager)
        let a = try repo.create(name: "a", parentId: nil)
        let b = try repo.create(name: "b", parentId: nil)
        let child = try repo.create(name: "child", parentId: a.id)

        try repo.move(id: child.id, toParent: b.id)
        XCTAssertEqual(try repo.notebook(id: child.id)?.parentId, b.id)

        try repo.move(id: child.id, toParent: nil)
        XCTAssertNil(try repo.notebook(id: child.id)?.parentId, "moving to root is allowed")
    }

    // MARK: - NotebookRepository: delete cascade + explicit chat/search cleanup

    func testDeletePapersCleansCascadeChatAndSearchRows() throws {
        let repo = NotebookRepository(database: manager)
        let noteRepo = NoteRepository(database: manager)
        let highlightRepo = HighlightRepository(database: manager)
        let chatRepo = ChatSessionRepository(database: manager)
        let search = SearchRepository(database: manager)

        let paper = try insertPaper(title: "quantum supremacy")
        try manager.dbQueue.write { db in try SearchIndex.indexPaper(paper, in: db) }

        // Paper-scoped note + a highlight-anchored comment, both indexed.
        var note = try noteRepo.createNote(paperId: paper.id, notebookId: nil, title: "n")
        note.body = "entangled qubits"
        try noteRepo.save(note)
        let highlight = Highlight(paperId: paper.id, page: 0, boundingBoxes: "[]",
                                  selectedText: "text")
        try highlightRepo.insertHighlights([highlight])
        _ = try highlightRepo.upsertComment(highlightId: highlight.id, paperId: paper.id,
                                            body: "decoherence")
        try chatRepo.saveMessages([ChatMessage(role: "user", content: "hi")],
                                  scope: .paper, scopeId: paper.id)

        // Everything is present before deletion.
        XCTAssertFalse(try search.search("quantum").isEmpty)
        XCTAssertFalse(try search.search("entangled").isEmpty)
        XCTAssertFalse(try search.search("decoherence").isEmpty)

        let deleted = try repo.deletePapers(ids: [paper.id])
        XCTAssertEqual(deleted.map(\.id), [paper.id])

        try manager.dbQueue.read { db in
            XCTAssertEqual(try Paper.fetchCount(db), 0)
            XCTAssertEqual(try Highlight.fetchCount(db), 0, "highlight cascades")
            XCTAssertEqual(try Comment.fetchCount(db), 0, "comment cascades")
            XCTAssertEqual(try Note.fetchCount(db), 0, "paper-scoped note cascades")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_session"), 0,
                           "paper chat sessions are explicitly deleted")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_index"), 0,
                           "all FTS rows for the paper are purged")
        }
        XCTAssertTrue(try search.search("quantum").isEmpty)
        XCTAssertTrue(try search.search("entangled").isEmpty)
        XCTAssertTrue(try search.search("decoherence").isEmpty)
    }

    func testDeletePapersEmptyInputIsNoOp() throws {
        let repo = NotebookRepository(database: manager)
        let result = try repo.deletePapers(ids: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testDeleteNotebookCascadesChildNotebooksAndOrphansPapersToUnfiled() throws {
        let repo = NotebookRepository(database: manager)
        let parent = try repo.create(name: "parent", parentId: nil)
        let child = try repo.create(name: "child", parentId: parent.id)
        let paper = try insertPaper(notebookId: child.id)

        try repo.delete(id: parent.id)

        XCTAssertNil(try repo.notebook(id: parent.id))
        XCTAssertNil(try repo.notebook(id: child.id), "child notebooks cascade-delete")
        // Paper survives with a nulled notebook_id (SET NULL), i.e. now Unfiled.
        let reloaded = try manager.dbQueue.read { db in try Paper.fetchOne(db, key: paper.id) }
        XCTAssertNotNil(reloaded)
        XCTAssertNil(reloaded?.notebookId)
        XCTAssertEqual(try repo.unfiledPapers().map(\.id), [paper.id])
    }

    // MARK: - NotebookRepository: recentlyViewedPapers ordering / limit / nulls

    func testRecentlyViewedExcludesNeverOpenedAndOrdersDescending() throws {
        let repo = NotebookRepository(database: manager)
        try insertPaper(title: "never", lastOpenedAt: nil)
        let mid = try insertPaper(title: "mid", lastOpenedAt: Date(timeIntervalSince1970: 200))
        let newest = try insertPaper(title: "newest", lastOpenedAt: Date(timeIntervalSince1970: 300))
        let oldest = try insertPaper(title: "oldest", lastOpenedAt: Date(timeIntervalSince1970: 100))

        let ordered = try repo.recentlyViewedPapers(limit: 10).map(\.id)
        XCTAssertEqual(ordered, [newest.id, mid.id, oldest.id],
                       "never-opened excluded; rest ordered by last_opened_at DESC")
    }

    func testRecentlyViewedRespectsLimitAndNonPositiveLimit() throws {
        let repo = NotebookRepository(database: manager)
        for i in 0..<5 {
            try insertPaper(title: "p\(i)", lastOpenedAt: Date(timeIntervalSince1970: Double(i)))
        }
        XCTAssertEqual(try repo.recentlyViewedPapers(limit: 2).count, 2)
        XCTAssertTrue(try repo.recentlyViewedPapers(limit: 0).isEmpty)
        XCTAssertTrue(try repo.recentlyViewedPapers(limit: -3).isEmpty)
    }

    // MARK: - NotebookRepository: pinning

    func testSetNotebookAndPaperPinnedTogglesTimestamp() throws {
        let repo = NotebookRepository(database: manager)
        let nb = try repo.create(name: "nb", parentId: nil)
        let paper = try insertPaper()

        try repo.setNotebookPinned(id: nb.id, pinned: true)
        try repo.setPaperPinned(paperId: paper.id, pinned: true)
        XCTAssertNotNil(try repo.notebook(id: nb.id)?.pinnedAt)
        XCTAssertNotNil(try manager.dbQueue.read { db in try Paper.fetchOne(db, key: paper.id) }?.pinnedAt)

        try repo.setNotebookPinned(id: nb.id, pinned: false)
        try repo.setPaperPinned(paperId: paper.id, pinned: false)
        XCTAssertNil(try repo.notebook(id: nb.id)?.pinnedAt)
        XCTAssertNil(try manager.dbQueue.read { db in try Paper.fetchOne(db, key: paper.id) }?.pinnedAt)
    }

    // MARK: - NotebookRepository: recursive paper set

    func testPapersUnderIncludesDescendantNotebooks() throws {
        let repo = NotebookRepository(database: manager)
        let root = try repo.create(name: "root", parentId: nil)
        let child = try repo.create(name: "child", parentId: root.id)
        let pRoot = try insertPaper(notebookId: root.id, importedAt: Date(timeIntervalSince1970: 100))
        let pChild = try insertPaper(notebookId: child.id, importedAt: Date(timeIntervalSince1970: 200))

        let ids = try repo.papersUnder(notebookId: root.id).map(\.id)
        XCTAssertEqual(Set(ids), [pRoot.id, pChild.id])
        XCTAssertEqual(ids.first, pChild.id, "ordered by imported_at DESC")
        XCTAssertTrue(try repo.containsPapers(notebookId: root.id))
    }

    // MARK: - HighlightRepository: multi-page insert ordering

    func testInsertHighlightsMultiPageOrdersByPageThenCreated() throws {
        let repo = HighlightRepository(database: manager)
        let paper = try insertPaper()
        let p2 = Highlight(paperId: paper.id, page: 2, boundingBoxes: "[]",
                           selectedText: "b", createdAt: Date(timeIntervalSince1970: 10))
        let p0a = Highlight(paperId: paper.id, page: 0, boundingBoxes: "[]",
                            selectedText: "a1", createdAt: Date(timeIntervalSince1970: 10))
        let p0b = Highlight(paperId: paper.id, page: 0, boundingBoxes: "[]",
                            selectedText: "a2", createdAt: Date(timeIntervalSince1970: 20))
        let p1 = Highlight(paperId: paper.id, page: 1, boundingBoxes: "[]",
                           selectedText: "c", createdAt: Date(timeIntervalSince1970: 5))
        try repo.insertHighlights([p2, p0a, p0b, p1])

        XCTAssertEqual(try repo.highlights(forPaper: paper.id).map(\.id),
                       [p0a.id, p0b.id, p1.id, p2.id],
                       "ordered by page, then created_at")
    }

    func testInsertHighlightsEmptyIsNoOp() throws {
        let repo = HighlightRepository(database: manager)
        let paper = try insertPaper()
        try repo.insertHighlights([])
        XCTAssertTrue(try repo.highlights(forPaper: paper.id).isEmpty)
    }

    // MARK: - HighlightRepository: comment upsert (create vs update)

    func testUpsertCommentCreatesThenUpdatesInPlace() throws {
        let repo = HighlightRepository(database: manager)
        let paper = try insertPaper()
        let highlight = Highlight(paperId: paper.id, page: 0, boundingBoxes: "[]",
                                  selectedText: "text")
        try repo.insertHighlights([highlight])

        let created = try repo.upsertComment(highlightId: highlight.id, paperId: paper.id,
                                             body: "first")
        XCTAssertNil(created.updatedAt, "create path leaves updated_at nil")

        let updated = try repo.upsertComment(highlightId: highlight.id, paperId: paper.id,
                                             body: "second")
        XCTAssertEqual(created.id, updated.id, "upsert reuses the same comment row")
        XCTAssertNotNil(updated.updatedAt, "update path stamps updated_at")
        XCTAssertEqual(try repo.comment(forHighlight: highlight.id)?.body, "second")
        try manager.dbQueue.read { db in
            XCTAssertEqual(try Comment.fetchCount(db), 1, "no duplicate comment created")
        }
    }

    func testUpsertCommentKeepsSearchIndexInSync() throws {
        let repo = HighlightRepository(database: manager)
        let search = SearchRepository(database: manager)
        let paper = try insertPaper()
        let highlight = Highlight(paperId: paper.id, page: 0, boundingBoxes: "[]",
                                  selectedText: "text")
        try repo.insertHighlights([highlight])

        _ = try repo.upsertComment(highlightId: highlight.id, paperId: paper.id,
                                   body: "mitochondria")
        XCTAssertEqual(try search.search("mitochondria").map(\.entityType), [.comment])

        _ = try repo.upsertComment(highlightId: highlight.id, paperId: paper.id,
                                   body: "ribosome")
        XCTAssertTrue(try search.search("mitochondria").isEmpty, "stale term is re-indexed away")
        XCTAssertFalse(try search.search("ribosome").isEmpty)
        // No duplicate FTS rows for the single comment.
        try manager.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_index"), 1)
        }
    }

    // MARK: - HighlightRepository: deletion paths + FTS maintenance

    func testDeleteHighlightPurgesCommentSearchIndex() throws {
        let repo = HighlightRepository(database: manager)
        let search = SearchRepository(database: manager)
        let paper = try insertPaper()
        let highlight = Highlight(paperId: paper.id, page: 0, boundingBoxes: "[]",
                                  selectedText: "text")
        try repo.insertHighlights([highlight])
        _ = try repo.upsertComment(highlightId: highlight.id, paperId: paper.id,
                                   body: "chromosome")
        XCTAssertFalse(try search.search("chromosome").isEmpty)

        try repo.deleteHighlight(id: highlight.id)
        try manager.dbQueue.read { db in
            XCTAssertEqual(try Comment.fetchCount(db), 0, "comment cascades with highlight")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_index"), 0)
        }
        XCTAssertTrue(try search.search("chromosome").isEmpty,
                      "cascaded comment's FTS row is removed explicitly")
    }

    func testDeleteCommentKeepsHighlightButPurgesSearchIndex() throws {
        let repo = HighlightRepository(database: manager)
        let search = SearchRepository(database: manager)
        let paper = try insertPaper()
        let highlight = Highlight(paperId: paper.id, page: 0, boundingBoxes: "[]",
                                  selectedText: "text")
        try repo.insertHighlights([highlight])
        _ = try repo.upsertComment(highlightId: highlight.id, paperId: paper.id, body: "enzyme")

        try repo.deleteComment(forHighlight: highlight.id)
        XCTAssertNil(try repo.comment(forHighlight: highlight.id))
        XCTAssertNotNil(try repo.highlight(id: highlight.id), "highlight is left intact")
        XCTAssertTrue(try search.search("enzyme").isEmpty)
    }

    func testCommentedHighlightIdsReflectsPresence() throws {
        let repo = HighlightRepository(database: manager)
        let paper = try insertPaper()
        let withComment = Highlight(paperId: paper.id, page: 0, boundingBoxes: "[]", selectedText: "a")
        let without = Highlight(paperId: paper.id, page: 1, boundingBoxes: "[]", selectedText: "b")
        try repo.insertHighlights([withComment, without])
        _ = try repo.upsertComment(highlightId: withComment.id, paperId: paper.id, body: "x")

        XCTAssertEqual(try repo.commentedHighlightIds(forPaper: paper.id), [withComment.id])
    }

    // MARK: - PageBookmarkRepository: toggle, dedupe, no unique constraint

    func testToggleBookmarkRoundTrips() throws {
        let repo = PageBookmarkRepository(database: manager)
        let paper = try insertPaper()

        XCTAssertTrue(try repo.toggle(paperId: paper.id, page: 3))
        XCTAssertTrue(try repo.isBookmarked(paperId: paper.id, page: 3))
        XCTAssertFalse(try repo.toggle(paperId: paper.id, page: 3))
        XCTAssertFalse(try repo.isBookmarked(paperId: paper.id, page: 3))
        XCTAssertTrue(try repo.bookmarkedPages(forPaper: paper.id).isEmpty)
    }

    func testToggleNeverCreatesDuplicateRowsAndSelfHealsExistingDupes() throws {
        let repo = PageBookmarkRepository(database: manager)
        let paper = try insertPaper()
        try repo.toggle(paperId: paper.id, page: 7)
        try repo.toggle(paperId: paper.id, page: 7) // remove
        try repo.toggle(paperId: paper.id, page: 7) // re-add
        try manager.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM page_bookmark WHERE paper_id = ? AND page = ?",
                arguments: [paper.id, 7]), 1)
        }

        // There is NO unique constraint on (paper_id, page): a direct duplicate
        // insert is accepted. bookmarkedPages() dedupes via Set, and toggle()
        // clears ALL duplicate rows in one shot (returns unbookmarked).
        try manager.dbQueue.write { db in
            try PageBookmark(paperId: paper.id, page: 7).insert(db)
        }
        XCTAssertEqual(try repo.bookmarkedPages(forPaper: paper.id), [7])
        XCTAssertFalse(try repo.toggle(paperId: paper.id, page: 7),
                       "toggle removes both duplicate rows at once")
        try manager.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM page_bookmark WHERE paper_id = ? AND page = ?",
                arguments: [paper.id, 7]), 0)
        }
    }

    func testBookmarksCascadeWithPaperDeletion() throws {
        let repo = PageBookmarkRepository(database: manager)
        let paper = try insertPaper()
        try repo.toggle(paperId: paper.id, page: 1)
        try manager.dbQueue.write { db in _ = try Paper.deleteOne(db, key: paper.id) }
        try manager.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM page_bookmark"), 0)
        }
    }

    // MARK: - SearchRepository: empty / punctuation-only / prefix

    func testSearchEmptyAndPunctuationOnlyReturnsNothing() throws {
        let search = SearchRepository(database: manager)
        XCTAssertTrue(try search.search("").isEmpty)
        XCTAssertTrue(try search.search("     ").isEmpty)
        XCTAssertTrue(try search.search("!!! --- ???").isEmpty,
                      "no alphanumeric tokens -> nil FTS query -> no crash, no results")
    }

    func testSearchIsPrefixMatchedAndSafeAgainstPunctuation() throws {
        let noteRepo = NoteRepository(database: manager)
        let search = SearchRepository(database: manager)
        var note = try noteRepo.createNote(paperId: nil, notebookId: nil, title: "t")
        note.body = "transformer architecture"
        try noteRepo.save(note)

        // Prefix match ("transform" -> "transform"*).
        XCTAssertEqual(try search.search("transform").map(\.id), [note.id])
        // Punctuation between tokens must not throw an FTS syntax error.
        XCTAssertEqual(try search.search("transformer: architecture!").map(\.id), [note.id])
    }
}
