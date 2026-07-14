import Foundation
import GRDB
import PDFKit
import AppKit
import CryptoKit

/// Errors thrown by `PDFImportService`.
public enum PDFImportError: Error {
    /// The source file could not be opened as a PDF by PDFKit.
    case cannotOpenPDF
}

/// Imports source PDFs into the app's managed `Papers/` directory, deduping by
/// content hash, and records them in the database (spec §3 Phase 1).
///
/// Import is dedupe-first: the source file's SHA-256 is computed before any
/// copying happens, so re-importing an already-known PDF is a cheap read-only
/// lookup that returns the existing `Paper` rather than creating a duplicate.
public final class PDFImportService {
    /// Result of an import attempt.
    public enum ImportOutcome {
        /// A new `Paper` was copied in and inserted.
        case imported(Paper)
        /// The source file's contents already match a previously-imported paper.
        case duplicate(existing: Paper)
    }

    private let dbQueue: DatabaseQueue
    private let papersDirectory: URL

    /// Creates the service, reading its storage handles from `database`.
    public init(database: DatabaseManager) {
        self.dbQueue = database.dbQueue
        self.papersDirectory = database.papersDirectory
    }

    /// Imports the PDF at `sourceURL`: dedupes by SHA-256, copies the file into
    /// `Papers/`, extracts page count and title, generates a page-1 thumbnail,
    /// and inserts a `Paper` row. Returns `.duplicate` (with no filesystem
    /// changes) if a paper with the same content hash already exists.
    public func importPDF(from sourceURL: URL) throws -> ImportOutcome {
        let sourceData = try Data(contentsOf: sourceURL)
        let digest = SHA256.hash(data: sourceData)
        let hash = digest.map { String(format: "%02x", $0) }.joined()

        let existing = try dbQueue.read { db in
            try Paper.filter(Column("file_hash") == hash).fetchOne(db)
        }
        if let existing {
            return .duplicate(existing: existing)
        }

        let paperId = UUID().uuidString

        // Validate the PDF BEFORE copying anything into Papers/, so an invalid or
        // unreadable file never leaves an orphaned copy behind (previously the
        // copy happened first, then validation threw and left the file).
        guard let doc = PDFDocument(url: sourceURL) else {
            throw PDFImportError.cannotOpenPDF
        }
        let pageCount = doc.pageCount

        try FileManager.default.createDirectory(
            at: papersDirectory,
            withIntermediateDirectories: true
        )

        let destinationURL = papersDirectory.appendingPathComponent("\(paperId).pdf")
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

        do {
            let rawTitle = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title: String
            if let rawTitle, !rawTitle.isEmpty {
                title = rawTitle
            } else {
                title = sourceURL.deletingPathExtension().lastPathComponent
            }

            if let page = doc.page(at: 0) {
                let thumbnailImage = page.thumbnail(of: CGSize(width: 240, height: 320), for: .cropBox)
                if let tiffData = thumbnailImage.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiffData),
                   let pngData = bitmap.representation(using: .png, properties: [:]) {
                    let thumbURL = papersDirectory.appendingPathComponent("\(paperId)_thumb.png")
                    try? pngData.write(to: thumbURL)
                }
            }

            let paper = Paper(
                id: paperId,
                title: title,
                filePath: "\(paperId).pdf",
                fileHash: hash,
                pageCount: pageCount
            )
            try dbQueue.write { db in
                try paper.insert(db)
                try SearchIndex.indexPaper(paper, in: db)
            }

            return .imported(paper)
        } catch {
            // A later failure (e.g. the DB insert) must not orphan the copied
            // file(s) on disk.
            try? FileManager.default.removeItem(at: destinationURL)
            try? FileManager.default.removeItem(at: papersDirectory.appendingPathComponent("\(paperId)_thumb.png"))
            throw error
        }
    }

    /// Absolute URL of `paper`'s copied PDF (`paper.filePath` is relative to `papersDirectory`).
    public static func fileURL(for paper: Paper, in papersDirectory: URL) -> URL {
        papersDirectory.appendingPathComponent(paper.filePath)
    }

    /// Absolute URL of `paper`'s cached page-1 thumbnail PNG.
    public static func thumbnailURL(for paper: Paper, in papersDirectory: URL) -> URL {
        papersDirectory.appendingPathComponent("\(paper.id)_thumb.png")
    }
}
