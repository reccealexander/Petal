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
