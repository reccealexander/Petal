import Foundation

/// Value that identifies a per-paper notes window. Distinct from the reader
/// window (keyed by the raw paper id String) so the two window groups don't clash.
struct NotesWindowID: Hashable, Codable {
    let paperId: String
}

extension Notification.Name {
    /// Posted to ask the open reader window for a paper to jump to a page.
    /// userInfo: ["paperId": String, "pageIndex": Int].
    static let readerJumpToHighlight = Notification.Name("PaperReader.readerJumpToHighlight")
}

/// A one-shot "jump to this page when the reader for this paper next finishes
/// loading" request. A freshly-opened reader window's PDFView coordinator isn't
/// subscribed to `.readerJumpToHighlight` yet, so callers set the target here
/// BEFORE `openWindow(value: paperId)`, and the reader consumes it on load.
@MainActor
enum PendingReaderJump {
    private static var targets: [String: Int] = [:]
    /// Record that the reader for `paperId` should jump to `pageIndex` on load.
    static func set(paperId: String, pageIndex: Int) { targets[paperId] = pageIndex }
    /// Return and clear any pending page for `paperId` (nil if none).
    static func take(paperId: String) -> Int? { targets.removeValue(forKey: paperId) }
}

/// Custom URL scheme embedded in notes markdown to link back to a highlight.
enum HighlightLink {
    static let scheme = "paperreader"

    /// Builds `paperreader://highlight/{highlightId}?page={pageIndex}`.
    static func url(highlightId: String, pageIndex: Int) -> URL {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = "highlight"
        comps.path = "/" + highlightId
        comps.queryItems = [URLQueryItem(name: "page", value: String(pageIndex))]
        return comps.url!
    }

    /// Parses a `paperreader://highlight/...` URL into its parts; nil if it isn't one.
    static func parse(_ url: URL) -> (highlightId: String, pageIndex: Int)? {
        guard url.scheme == scheme, url.host == "highlight" else { return nil }
        let id = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard !id.isEmpty else { return nil }
        let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "page" })?.value
            .flatMap(Int.init) ?? 0
        return (id, page)
    }
}
