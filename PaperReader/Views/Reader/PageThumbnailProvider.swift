import Foundation
import PDFKit
import AppKit

/// Generates and caches per-page thumbnail images for a single paper's PDF,
/// backing the `PageThumbnailSidebar` (Session 6 Part A).
///
/// Mirrors the NSImage→PNG conversion `PDFImportService` uses for its page-1
/// cover thumbnail, but keyed per page and stored alongside it in the paper's
/// directory as `<paperId>_page_<index>.png` (distinct from `<paperId>_thumb.png`).
///
/// Thumbnails are generated lazily — only when a visible sidebar row asks for
/// one via `requestThumbnail(forPage:)` — so opening a long PDF never blocks
/// the main thread rendering every page up front. Once generated, a page's
/// thumbnail is cached both in memory (for smooth scrolling within a session)
/// and on disk (so reopening the paper is instant).
@MainActor
final class PageThumbnailProvider: ObservableObject {
    private let paperId: String
    private let document: PDFDocument?
    private let papersDirectory: URL
    private let thumbnailSize = CGSize(width: 160, height: 200)

    /// In-memory cache of generated/loaded thumbnails, keyed by page index.
    /// `@Published` so sidebar rows redraw as thumbnails arrive.
    @Published private(set) var memoryCache: [Int: NSImage] = [:]

    private var pendingRequests: Set<Int> = []

    init(paperId: String, document: PDFDocument?, papersDirectory: URL) {
        self.paperId = paperId
        self.document = document
        self.papersDirectory = papersDirectory
    }

    var pageCount: Int { document?.pageCount ?? 0 }

    private func diskURL(forPage index: Int) -> URL {
        papersDirectory.appendingPathComponent("\(paperId)_page_\(index).png")
    }

    /// Synchronous, cache-only lookup — safe to call from a SwiftUI view body.
    func thumbnail(forPage index: Int) -> NSImage? {
        memoryCache[index]
    }

    /// Ensures a thumbnail for `index` is (eventually) in the in-memory cache.
    /// No-op if already cached or already in flight. Checks the on-disk PNG
    /// first; only falls back to rendering the PDF page if no cached file
    /// exists yet, then writes the render back to disk for next time.
    func requestThumbnail(forPage index: Int) {
        guard memoryCache[index] == nil, !pendingRequests.contains(index) else { return }
        guard document != nil, index >= 0, index < pageCount else { return }
        pendingRequests.insert(index)

        let url = diskURL(forPage: index)
        let size = thumbnailSize

        Task.detached(priority: .userInitiated) { [weak self] in
            if let data = try? Data(contentsOf: url), let image = NSImage(data: data) {
                await MainActor.run {
                    self?.memoryCache[index] = image
                    self?.pendingRequests.remove(index)
                }
                return
            }
            await self?.generateAndCache(index: index, url: url, size: size)
        }
    }

    /// Renders the page thumbnail (must run on the main actor — PDFKit's
    /// `PDFDocument`/`PDFPage` are not safe to touch off it), publishes it to
    /// the in-memory cache immediately, then writes the PNG to disk in the
    /// background for future launches.
    private func generateAndCache(index: Int, url: URL, size: CGSize) async {
        defer { pendingRequests.remove(index) }
        guard let document, let page = document.page(at: index) else { return }

        let image = page.thumbnail(of: size, for: .cropBox)
        memoryCache[index] = image

        Task.detached(priority: .utility) {
            if let tiffData = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                try? pngData.write(to: url)
            }
        }
    }
}
