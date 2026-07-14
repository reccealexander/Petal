import XCTest
import GRDB
@testable import PetalCore

/// Adversarial edge-case coverage for the model layer's codecs and Codable
/// mappings: JSON codecs (linked highlight ids, chat messages), enum-from-raw
/// edges, the provider-neutral `SyncValue` bridge, `SyncedEntity` key handling,
/// and every model's Codable round-trip through its snake_case GRDB columns.
///
/// All assertions describe *current* behavior. Where a codec is designed to
/// "fail safe" (return `[]`/`"[]"` rather than throw or crash), the tests pin
/// that guarantee against malformed / null / non-array / garbage input.
final class ModelCodecEdgeCaseTests: XCTestCase {

    // A fixed, whole-second instant. GRDB persists dates as
    // "yyyy-MM-dd HH:mm:ss.SSS" (millisecond precision, UTC); using whole
    // seconds keeps insert→fetch round-trips exactly equal.
    private let fixedDate = Date(timeIntervalSince1970: 1_600_000_000)
    private let otherDate = Date(timeIntervalSince1970: 1_600_000_500)

    private var manager: DatabaseManager!
    private var dbQueue: DatabaseQueue { manager.dbQueue }

    override func setUpWithError() throws {
        manager = try DatabaseManager.inMemory()
    }

    override func tearDownWithError() throws {
        manager = nil
    }

    // MARK: - NoteRepository linked-id JSON codec

    func testLinkedIdsRoundTrip() {
        let ids = ["a", "b", "c"]
        let json = NoteRepository.encodeLinkedIds(ids)
        XCTAssertEqual(NoteRepository.decodeLinkedIds(json), ids)
    }

    func testLinkedIdsEmptyArrayEncodesToBracketsAndBack() {
        XCTAssertEqual(NoteRepository.encodeLinkedIds([]), "[]")
        XCTAssertEqual(NoteRepository.decodeLinkedIds("[]"), [])
    }

    func testLinkedIdsPreservesSpecialCharacters() {
        let ids = ["quote\"inside", "emoji 🌸", "new\nline", "コロン:test", "back\\slash"]
        let json = NoteRepository.encodeLinkedIds(ids)
        XCTAssertEqual(NoteRepository.decodeLinkedIds(json), ids)
    }

    func testLinkedIdsDecodeFailsSafeOnMalformedInput() {
        // Every one of these must default to [] rather than crash.
        XCTAssertEqual(NoteRepository.decodeLinkedIds(nil), [])
        XCTAssertEqual(NoteRepository.decodeLinkedIds(""), [])
        XCTAssertEqual(NoteRepository.decodeLinkedIds("null"), [])
        XCTAssertEqual(NoteRepository.decodeLinkedIds("not json at all"), [])
        XCTAssertEqual(NoteRepository.decodeLinkedIds("{\"not\":\"an array\"}"), [])
        XCTAssertEqual(NoteRepository.decodeLinkedIds("[1, 2, 3]"), [])          // wrong element type
        XCTAssertEqual(NoteRepository.decodeLinkedIds("[\"a\", null]"), [])       // null element
        XCTAssertEqual(NoteRepository.decodeLinkedIds("[\"unterminated"), [])
        XCTAssertEqual(NoteRepository.decodeLinkedIds("\"a plain string\""), [])
    }

    // MARK: - ChatMessage JSON codec

    func testChatMessagesRoundTripWithWholeSecondDates() {
        let messages = [
            ChatMessage(id: UUID(), role: "user", content: "hi", timestamp: fixedDate),
            ChatMessage(id: UUID(), role: "assistant", content: "hello 🌼\nsecond line", timestamp: otherDate)
        ]
        let json = ChatSessionRepository.encode(messages)
        XCTAssertEqual(ChatSessionRepository.decode(json), messages)
    }

    func testChatMessagesEmptyRoundTrip() {
        XCTAssertEqual(ChatSessionRepository.encode([]), "[]")
        XCTAssertEqual(ChatSessionRepository.decode("[]"), [])
    }

    func testChatMessagesDecodeFailsSafeOnMalformedInput() {
        XCTAssertEqual(ChatSessionRepository.decode(""), [])
        XCTAssertEqual(ChatSessionRepository.decode("null"), [])
        XCTAssertEqual(ChatSessionRepository.decode("garbage"), [])
        XCTAssertEqual(ChatSessionRepository.decode("{\"role\":\"user\"}"), [])   // object, not array
        XCTAssertEqual(ChatSessionRepository.decode("[{\"role\":\"user\"}]"), []) // missing required keys
    }

    /// The ChatMessage codec uses `.iso8601`, which omits fractional seconds.
    /// A timestamp with sub-second precision is therefore truncated on the
    /// round-trip: the decoded instant has no fractional component. This pins
    /// that lossy-but-non-crashing behavior (see report finding #1).
    func testChatMessageTimestampLosesSubSecondPrecision() {
        let fractional = Date(timeIntervalSince1970: 1_600_000_000.75)
        let message = ChatMessage(id: UUID(), role: "user", content: "x", timestamp: fractional)
        let decoded = ChatSessionRepository.decode(ChatSessionRepository.encode([message]))
        XCTAssertEqual(decoded.count, 1)
        let t = try! XCTUnwrap(decoded.first).timestamp.timeIntervalSince1970
        // Fractional component was dropped by the ISO-8601 encoder.
        XCTAssertEqual(t, t.rounded(.towardZero), accuracy: 0.0005,
                       "iso8601 chat-message timestamps carry no sub-second precision")
        // ...and it differs from the original fractional instant.
        XCTAssertNotEqual(decoded.first, message)
    }

    // MARK: - HighlightColor raw-value mapping

    func testHighlightColorRawValues() {
        XCTAssertEqual(HighlightColor.yellow.rawValue, "yellow")
        XCTAssertEqual(HighlightColor.green.rawValue, "green")
        XCTAssertEqual(HighlightColor.blue.rawValue, "blue")
        XCTAssertEqual(HighlightColor.pink.rawValue, "pink")
        XCTAssertEqual(HighlightColor.allCases.count, 4)
        for c in HighlightColor.allCases {
            XCTAssertEqual(c.id, c.rawValue)
            XCTAssertEqual(c.displayName, c.rawValue.capitalized)
        }
    }

    func testHighlightColorFromUnknownRawIsNil() {
        XCTAssertNil(HighlightColor(rawValue: "orange"))
        XCTAssertNil(HighlightColor(rawValue: ""))
        XCTAssertNil(HighlightColor(rawValue: "Yellow"))   // case-sensitive
        // The renderer/taxonomy fall back to .yellow for unknown strings.
        XCTAssertEqual(HighlightColor(rawValue: "who knows") ?? .yellow, .yellow)
    }

    // MARK: - ChatSession.Scope raw-value mapping

    func testChatSessionScopeRawValues() {
        XCTAssertEqual(ChatSession.Scope.paper.rawValue, "paper")
        XCTAssertEqual(ChatSession.Scope.notebook.rawValue, "notebook")
        XCTAssertNil(ChatSession.Scope(rawValue: "global"))
        XCTAssertNil(ChatSession.Scope(rawValue: ""))
        // The initializer stores the raw string form.
        XCTAssertEqual(ChatSession(scope: .notebook, scopeId: "n1").scope, "notebook")
    }

    // MARK: - SyncValue <-> DatabaseValue bridge

    func testSyncValueRoundTripsEveryStorageCase() {
        let cases: [SyncValue] = [
            .string(""),
            .string("hello 🌸 コロン"),
            .int(0),
            .int(-1),
            .int(Int64.max),
            .int(Int64.min),
            .double(0),
            .double(-3.5),
            .double(.pi),
            .data(Data([0x00, 0x01, 0xFF])),
            .null
        ]
        for value in cases {
            let round = SyncValue(databaseValue: value.databaseValue)
            XCTAssertEqual(round, value, "SyncValue did not survive databaseValue round-trip: \(value)")
        }
    }

    func testSyncValueMapsRawDatabaseValues() {
        XCTAssertEqual(SyncValue(databaseValue: "abc".databaseValue), .string("abc"))
        XCTAssertEqual(SyncValue(databaseValue: Int64(42).databaseValue), .int(42))
        XCTAssertEqual(SyncValue(databaseValue: 1.5.databaseValue), .double(1.5))
        XCTAssertEqual(SyncValue(databaseValue: DatabaseValue.null), .null)
        // Swift `Int` binds through as an integer storage, surfacing as .int.
        XCTAssertEqual(SyncValue(databaseValue: 7.databaseValue), .int(7))
    }

    func testSyncValueEmptyDataMapping() {
        // Documents how an empty blob is classified by this GRDB version.
        let round = SyncValue(databaseValue: SyncValue.data(Data()).databaseValue)
        XCTAssertEqual(round, .data(Data()),
                       "Empty Data should round-trip as .data(empty), not collapse to .null")
    }

    // MARK: - SyncedEntity key handling

    func testSyncedEntityKeyValuesSingleAndComposite() {
        let paper = try! XCTUnwrap(SyncedEntity.lookup("paper"))
        XCTAssertEqual(paper.keyColumns, ["id"])
        XCTAssertEqual(paper.keyValues(fromRecordName: "some-uuid"), ["some-uuid"])
        // A single-key record name that happens to contain ':' is NOT split.
        XCTAssertEqual(paper.keyValues(fromRecordName: "a:b"), ["a:b"])

        let paperTag = try! XCTUnwrap(SyncedEntity.lookup("paper_tag"))
        XCTAssertEqual(paperTag.keyColumns, ["paper_id", "tag_id"])
        XCTAssertEqual(paperTag.keyValues(fromRecordName: "pid:tid"), ["pid", "tid"])
    }

    func testSyncedEntityKeyExpression() {
        let paper = try! XCTUnwrap(SyncedEntity.lookup("paper"))
        XCTAssertEqual(paper.keyExpression(alias: "NEW"), "NEW.\"id\"")

        let paperTag = try! XCTUnwrap(SyncedEntity.lookup("paper_tag"))
        XCTAssertEqual(paperTag.keyExpression(alias: "NEW"),
                       "NEW.\"paper_id\"||':'||NEW.\"tag_id\"")
    }

    func testSyncedEntityLookupUnknownIsNil() {
        XCTAssertNil(SyncedEntity.lookup("search_index"))  // derived, never synced
        XCTAssertNil(SyncedEntity.lookup(""))
        XCTAssertNil(SyncedEntity.lookup("nope"))
        // Registry is in FK-safe order: parents (notebook/paper/tag) precede children.
        let types = SyncedEntity.all.map(\.entityType)
        XCTAssertLessThan(types.firstIndex(of: "paper")!, types.firstIndex(of: "highlight")!)
        XCTAssertLessThan(types.firstIndex(of: "highlight")!, types.firstIndex(of: "comment")!)
    }

    // MARK: - Model Codable round-trips through GRDB snake_case columns

    func testPaperRoundTripAllFields() throws {
        let paper = Paper(
            id: "paper-1",
            notebookId: nil,
            title: "Attention Is All You Need",
            authors: "Vaswani et al.",
            doi: "10.1000/xyz",
            arxivId: "1706.03762",
            filePath: "a.pdf",
            fileHash: "deadbeef",
            pageCount: 15,
            importedAt: fixedDate,
            lastOpenedAt: otherDate,
            freeSpaceX: -12.5,
            freeSpaceY: 340.25,
            pinnedAt: otherDate,
            lastPage: 7,
            lastScrollOffset: 88.5,
            readingStatus: "in_progress",
            furthestPageRead: 9
        )
        try dbQueue.write { try paper.insert($0) }
        let fetched = try dbQueue.read { try Paper.fetchOne($0, key: "paper-1") }
        XCTAssertEqual(fetched, paper)

        // Explicitly confirm the snake_case column mapping.
        let row = try dbQueue.read { try Row.fetchOne($0, sql: "SELECT * FROM paper WHERE id = ?", arguments: ["paper-1"]) }
        XCTAssertEqual(row?["arxiv_id"], "1706.03762")
        XCTAssertEqual(row?["free_space_x"], -12.5)
        XCTAssertEqual(row?["reading_status"], "in_progress")
        XCTAssertEqual(row?["furthest_page_read"], 9)
    }

    func testPaperRoundTripMinimalNullableFields() throws {
        let paper = Paper(id: "paper-min", filePath: "b.pdf", importedAt: fixedDate)
        try dbQueue.write { try paper.insert($0) }
        let fetched = try dbQueue.read { try Paper.fetchOne($0, key: "paper-min") }
        XCTAssertEqual(fetched, paper)
        XCTAssertNil(fetched?.notebookId)
        XCTAssertNil(fetched?.lastOpenedAt)
        XCTAssertNil(fetched?.pinnedAt)
        XCTAssertEqual(fetched?.readingStatus, "unread")
        XCTAssertEqual(fetched?.furthestPageRead, 0)
    }

    /// The Paper model stores `readingStatus` as a raw String with no enum
    /// coercion, so an unrecognized value round-trips verbatim.
    func testPaperReadingStatusStoresArbitraryStringVerbatim() throws {
        let paper = Paper(id: "paper-weird", filePath: "c.pdf", importedAt: fixedDate, readingStatus: "totally-made-up")
        try dbQueue.write { try paper.insert($0) }
        let fetched = try dbQueue.read { try Paper.fetchOne($0, key: "paper-weird") }
        XCTAssertEqual(fetched?.readingStatus, "totally-made-up")
    }

    func testNoteRoundTripWithRtfAndLinkedIds() throws {
        let note = Note(
            id: "note-1",
            paperId: nil,
            notebookId: nil,
            title: "Title",
            body: "plain text projection",
            bodyRtf: Data([0x7B, 0x5C, 0x72, 0x74, 0x66]),   // "{\rtf" bytes
            linkedHighlightIds: NoteRepository.encodeLinkedIds(["h1", "h2"]),
            createdAt: fixedDate,
            updatedAt: otherDate
        )
        try dbQueue.write { try note.insert($0) }
        let fetched = try dbQueue.read { try Note.fetchOne($0, key: "note-1") }
        XCTAssertEqual(fetched, note)
        XCTAssertEqual(fetched?.bodyRtf, note.bodyRtf)
    }

    func testNoteRoundTripNilRtfAndNilUpdatedAt() throws {
        let note = Note(id: "note-2", body: "b", bodyRtf: nil, linkedHighlightIds: nil, createdAt: fixedDate, updatedAt: nil)
        try dbQueue.write { try note.insert($0) }
        let fetched = try dbQueue.read { try Note.fetchOne($0, key: "note-2") }
        XCTAssertEqual(fetched, note)
        XCTAssertNil(fetched?.bodyRtf)
        XCTAssertNil(fetched?.linkedHighlightIds)
        XCTAssertNil(fetched?.updatedAt)
    }

    func testHighlightRoundTrip() throws {
        let boxes = BoundingBoxJSON.sampleTwoRects
        let highlight = Highlight(
            id: "hl-1",
            paperId: nil,
            page: 0,
            boundingBoxes: boxes,
            color: "green",
            selectedText: "self-attention",
            createdAt: fixedDate
        )
        try dbQueue.write { try highlight.insert($0) }
        let fetched = try dbQueue.read { try Highlight.fetchOne($0, key: "hl-1") }
        XCTAssertEqual(fetched, highlight)
        XCTAssertEqual(fetched?.boundingBoxes, boxes)
    }

    func testCommentRoundTripAllNilOptionals() throws {
        let comment = Comment(id: "cm-1", highlightId: nil, paperId: nil, body: "note", createdAt: fixedDate, updatedAt: nil)
        try dbQueue.write { try comment.insert($0) }
        let fetched = try dbQueue.read { try Comment.fetchOne($0, key: "cm-1") }
        XCTAssertEqual(fetched, comment)
    }

    func testNotebookRoundTripAllFields() throws {
        let notebook = Notebook(
            id: "nb-1",
            name: "Research",
            parentId: nil,
            createdAt: fixedDate,
            sortOrder: 3,
            aiSummary: "summary text",
            aiSummaryNoteCount: 2,
            aiSummaryPaperIdsHash: "hashvalue",
            aiSummaryPaperCount: 5,
            pinnedAt: otherDate
        )
        try dbQueue.write { try notebook.insert($0) }
        let fetched = try dbQueue.read { try Notebook.fetchOne($0, key: "nb-1") }
        XCTAssertEqual(fetched, notebook)
    }

    func testTagRoundTrip() throws {
        let tag = Tag(id: "tag-1", name: "graphene")
        try dbQueue.write { try tag.insert($0) }
        let fetched = try dbQueue.read { try Tag.fetchOne($0, key: "tag-1") }
        XCTAssertEqual(fetched, tag)
    }

    func testPaperTagCompositeKeyRoundTrip() throws {
        let paper = Paper(id: "p-pt", filePath: "d.pdf", importedAt: fixedDate)
        let tag = Tag(id: "t-pt", name: "physics")
        let link = PaperTag(paperId: "p-pt", tagId: "t-pt")
        try dbQueue.write { db in
            try paper.insert(db)
            try tag.insert(db)
            try link.insert(db)
        }
        // Fetch by the composite primary key.
        let fetched = try dbQueue.read { db in
            try PaperTag.fetchOne(db, sql: "SELECT * FROM paper_tag WHERE paper_id = ? AND tag_id = ?", arguments: ["p-pt", "t-pt"])
        }
        XCTAssertEqual(fetched, link)
        XCTAssertEqual(fetched?.paperId, "p-pt")
        XCTAssertEqual(fetched?.tagId, "t-pt")
    }

    func testPageBookmarkRoundTrip() throws {
        let paper = Paper(id: "p-bm", filePath: "e.pdf", importedAt: fixedDate)
        let bookmark = PageBookmark(id: "bm-1", paperId: "p-bm", page: 0)   // zero-based page index
        try dbQueue.write { db in
            try paper.insert(db)
            try bookmark.insert(db)
        }
        let fetched = try dbQueue.read { try PageBookmark.fetchOne($0, key: "bm-1") }
        XCTAssertEqual(fetched, bookmark)
        XCTAssertEqual(fetched?.page, 0)
    }

    func testChatSessionRoundTrip() throws {
        let messages = [ChatMessage(id: UUID(), role: "user", content: "q", timestamp: fixedDate)]
        let session = ChatSession(
            id: "cs-1",
            scope: .paper,
            scopeId: "p-cs",
            messages: ChatSessionRepository.encode(messages),
            createdAt: fixedDate,
            updatedAt: nil
        )
        try dbQueue.write { try session.insert($0) }
        let fetched = try dbQueue.read { try ChatSession.fetchOne($0, key: "cs-1") }
        XCTAssertEqual(fetched, session)
        XCTAssertEqual(fetched?.scope, "paper")
        XCTAssertEqual(ChatSessionRepository.decode(fetched!.messages), messages)
    }

    func testSyncStateRowRoundTrip() throws {
        let row = SyncStateRow(
            entityType: "paper",
            entityId: "p-1",
            dirty: true,
            deleted: false,
            ckChangeTag: "tag-123",
            ckSystemFields: Data([0x01, 0x02]),
            localUpdatedAt: "2020-09-13 12:26:40.000"
        )
        try dbQueue.write { try row.insert($0) }
        let fetched = try dbQueue.read { db in
            try SyncStateRow.fetchOne(db, sql: "SELECT * FROM sync_state WHERE entity_type = ? AND entity_id = ?", arguments: ["paper", "p-1"])
        }
        XCTAssertEqual(fetched?.entityType, "paper")
        XCTAssertEqual(fetched?.entityId, "p-1")
        XCTAssertEqual(fetched?.dirty, true)
        XCTAssertEqual(fetched?.deleted, false)
        XCTAssertEqual(fetched?.ckChangeTag, "tag-123")
        XCTAssertEqual(fetched?.ckSystemFields, Data([0x01, 0x02]))
        XCTAssertEqual(fetched?.localUpdatedAt, "2020-09-13 12:26:40.000")
    }
}

/// Small helper producing valid bounding-box JSON strings without importing the
/// app-layer `BoundingBoxCodec` (which lives in the executable target and is not
/// visible to `PetalCore` tests).
private enum BoundingBoxJSON {
    static let sampleTwoRects = "[{\"x\":1,\"y\":2,\"width\":3,\"height\":4},{\"x\":-5,\"y\":0.5,\"width\":10,\"height\":20}]"
}
