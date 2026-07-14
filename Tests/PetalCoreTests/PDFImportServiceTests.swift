import XCTest
import GRDB
import CoreGraphics
import AppKit
@testable import PetalCore

/// Exercises `PDFImportService`'s import flow (spec §3 Phase 1): hashing,
/// dedupe-before-copy, file/thumbnail materialization, and title fallback.
final class PDFImportServiceTests: XCTestCase {
    private var manager: DatabaseManager!
    private var service: PDFImportService!
    private var dbQueue: DatabaseQueue { manager.dbQueue }

    override func setUpWithError() throws {
        manager = try DatabaseManager.inMemory()
        service = PDFImportService(database: manager)
    }

    override func tearDownWithError() throws {
        manager = nil
        service = nil
    }

    // MARK: - Fresh import

    func testImportCreatesPaperFileAndThumbnail() throws {
        let source = try makeSamplePDF(named: "attention.pdf", title: "Attention Is All You Need")

        let outcome = try service.importPDF(from: source)
        let paper = try imported(outcome)

        XCTAssertEqual(paper.pageCount, 1)
        XCTAssertEqual(paper.title, "Attention Is All You Need")
        XCTAssertNotNil(paper.fileHash)
        XCTAssertFalse(paper.fileHash?.isEmpty ?? true)

        let fileURL = PDFImportService.fileURL(for: paper, in: manager.papersDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "Copied PDF should exist on disk")

        let thumbURL = PDFImportService.thumbnailURL(for: paper, in: manager.papersDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbURL.path), "Thumbnail PNG should exist on disk")

        let count = try dbQueue.read { db in try Paper.fetchCount(db) }
        XCTAssertEqual(count, 1)
    }

    // MARK: - Title fallback

    func testTitleFallsBackToFilenameWhenNoMetadata() throws {
        let source = try makeSamplePDF(named: "graphene-review.pdf", title: nil)

        let outcome = try service.importPDF(from: source)
        let paper = try imported(outcome)

        XCTAssertEqual(paper.title, "graphene-review")
    }

    // MARK: - Duplicate detection

    func testReimportingSameFileIsDetectedAsDuplicate() throws {
        let source = try makeSamplePDF(named: "duplicate-me.pdf", title: "Duplicate Me")

        let firstOutcome = try service.importPDF(from: source)
        let firstPaper = try imported(firstOutcome)

        let secondOutcome = try service.importPDF(from: source)
        guard case .duplicate(let existing) = secondOutcome else {
            XCTFail("Expected .duplicate outcome, got \(secondOutcome)")
            return
        }
        XCTAssertEqual(existing.id, firstPaper.id)

        let count = try dbQueue.read { db in try Paper.fetchCount(db) }
        XCTAssertEqual(count, 1, "Re-importing the same content must not create a second row")

        let pdfsInPapersDir = try FileManager.default.contentsOfDirectory(
            at: manager.papersDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "pdf" }
        XCTAssertEqual(pdfsInPapersDir.count, 1, "Re-importing must not copy a second PDF into Papers/")
    }

    // MARK: - Schema

    func testFileHashColumnExists() throws {
        let columnNames = try dbQueue.read { db -> [String] in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(paper)")
            return rows.compactMap { $0["name"] as String? }
        }
        XCTAssertTrue(columnNames.contains("file_hash"), "paper table must have a file_hash column")
    }

    // MARK: - Helpers

    private func imported(_ outcome: PDFImportService.ImportOutcome, file: StaticString = #filePath, line: UInt = #line) throws -> Paper {
        guard case .imported(let paper) = outcome else {
            XCTFail("Expected .imported outcome, got \(outcome)", file: file, line: line)
            throw XCTSkip("Cannot continue without an imported paper")
        }
        return paper
    }

    @discardableResult
    private func makeSamplePDF(named name: String, title: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfimport-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
            throw XCTSkip("Could not create PDF context")
        }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 40, y: 40, width: 120, height: 120))
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }
}
