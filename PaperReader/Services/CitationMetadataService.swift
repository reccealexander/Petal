import Foundation

/// Optional online enrichment for citation metadata. When a paper carries a
/// DOI it queries CrossRef; when it carries an arXiv id it queries the arXiv
/// API. Both paths **degrade gracefully**: any missing identifier, network
/// failure, non-2xx response, or parse error falls back to the metadata already
/// assembled from the stored `Paper`, so citations always work offline.
///
/// Speaks the wire protocol directly via `URLSession`, mirroring the app's
/// existing raw-HTTPS clients (`GeminiClient`, `ClaudeClient`).
public final class CitationMetadataService: @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Returns the best available metadata for `paper`, enriching from CrossRef
    /// or arXiv when possible and never throwing — the stored-`Paper` baseline
    /// is always a valid result.
    public func enrichedMetadata(for paper: Paper) async -> CitationMetadata {
        await enrichedMetadata(from: CitationMetadata(paper: paper))
    }

    /// Enriches an already-assembled (Sendable) baseline. Prefer this from the
    /// UI so a non-Sendable `Paper` never crosses actor boundaries.
    public func enrichedMetadata(from fallback: CitationMetadata) async -> CitationMetadata {
        if let doi = fallback.doi, !doi.isEmpty,
           let enriched = try? await fetchCrossRef(doi: doi, fallback: fallback) {
            return enriched
        }

        if let arxivId = fallback.arxivId, !arxivId.isEmpty,
           let enriched = try? await fetchArxiv(id: arxivId, fallback: fallback) {
            return enriched
        }

        return fallback
    }

    /// Whether enrichment could plausibly add anything (there is an identifier
    /// to look up). Lets the UI decide whether to show a loading state at all.
    public static func canEnrich(_ paper: Paper) -> Bool {
        let doi = paper.doi?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let arxiv = paper.arxivId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !doi.isEmpty || !arxiv.isEmpty
    }

    // MARK: - CrossRef

    private func fetchCrossRef(doi: String, fallback: CitationMetadata) async throws -> CitationMetadata {
        let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
        guard let url = URL(string: "https://api.crossref.org/works/\(encoded)") else {
            return fallback
        }

        var request = URLRequest(url: url)
        // CrossRef asks callers to identify themselves in the User-Agent.
        request.setValue("PaperReader/1.0 (mailto:support@paperreader.app)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any] else {
            return fallback
        }

        return Self.mergeCrossRef(message, into: fallback)
    }

    /// Overlays CrossRef fields onto the fallback, keeping fallback values where
    /// CrossRef omits them.
    static func mergeCrossRef(_ message: [String: Any], into fallback: CitationMetadata) -> CitationMetadata {
        var result = fallback

        if let authorItems = message["author"] as? [[String: Any]] {
            let parsed = authorItems.compactMap { item -> CitationAuthor? in
                let given = (item["given"] as? String)?.trimmingCharacters(in: .whitespaces)
                let family = (item["family"] as? String)?.trimmingCharacters(in: .whitespaces)
                if let family, !family.isEmpty {
                    return CitationAuthor(given: given, family: family)
                }
                if let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                    return CitationAuthor(given: nil, family: name)
                }
                return nil
            }
            if !parsed.isEmpty {
                result.authors = parsed
            }
        }

        if let titles = message["title"] as? [String], let title = titles.first, !title.isEmpty {
            result.title = title
        }

        if let containers = message["container-title"] as? [String],
           let container = containers.first, !container.isEmpty {
            result.container = container
        }

        if let publisher = message["publisher"] as? String, !publisher.isEmpty {
            result.publisher = publisher
        }
        if let volume = message["volume"] as? String, !volume.isEmpty {
            result.volume = volume
        }
        if let issue = message["issue"] as? String, !issue.isEmpty {
            result.issue = issue
        }
        if let page = message["page"] as? String, !page.isEmpty {
            result.pages = page
        }
        if let doi = message["DOI"] as? String, !doi.isEmpty {
            result.doi = doi
        }
        if let year = crossRefYear(from: message) {
            result.year = year
        }

        return result
    }

    /// Extracts the publication year from CrossRef's nested date-parts, trying
    /// the most specific date fields first.
    private static func crossRefYear(from message: [String: Any]) -> Int? {
        for key in ["published-print", "published-online", "published", "issued", "created"] {
            if let dateObj = message[key] as? [String: Any],
               let dateParts = dateObj["date-parts"] as? [[Int]],
               let first = dateParts.first,
               let year = first.first {
                return year
            }
        }
        return nil
    }

    // MARK: - arXiv

    private func fetchArxiv(id: String, fallback: CitationMetadata) async throws -> CitationMetadata {
        // Strip any "arXiv:" prefix the stored id may carry.
        let bare = id
            .replacingOccurrences(of: "arXiv:", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        let encoded = bare.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bare
        guard let url = URL(string: "https://export.arxiv.org/api/query?id_list=\(encoded)") else {
            return fallback
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return fallback
        }

        let parser = ArxivAtomParser()
        guard let entry = parser.parse(data) else { return fallback }
        return Self.mergeArxiv(entry, arxivId: bare, into: fallback)
    }

    static func mergeArxiv(_ entry: ArxivEntry, arxivId: String, into fallback: CitationMetadata) -> CitationMetadata {
        var result = fallback
        result.arxivId = arxivId

        if let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            // arXiv titles arrive with embedded newlines/extra spaces.
            result.title = title.replacingOccurrences(
                of: #"\s+"#, with: " ", options: .regularExpression
            )
        }
        if !entry.authors.isEmpty {
            result.authors = entry.authors.map { CitationAuthor.parse(from: $0).first ?? CitationAuthor(family: $0) }
        }
        if let year = entry.year {
            result.year = year
        }
        if let journalRef = entry.journalRef, !journalRef.isEmpty {
            result.container = journalRef
        } else if result.container == nil {
            result.container = "arXiv"
        }
        if let doi = entry.doi, !doi.isEmpty {
            result.doi = doi
        }

        return result
    }
}

/// One parsed arXiv Atom `<entry>`.
public struct ArxivEntry: Equatable, Sendable {
    public var title: String?
    public var authors: [String]
    public var year: Int?
    public var journalRef: String?
    public var doi: String?

    public init(
        title: String? = nil,
        authors: [String] = [],
        year: Int? = nil,
        journalRef: String? = nil,
        doi: String? = nil
    ) {
        self.title = title
        self.authors = authors
        self.year = year
        self.journalRef = journalRef
        self.doi = doi
    }
}

/// Minimal `XMLParser` delegate that pulls the first entry's fields out of an
/// arXiv Atom feed. Only the handful of elements needed for a citation.
final class ArxivAtomParser: NSObject, XMLParserDelegate {
    private var entry = ArxivEntry()
    private var currentElement = ""
    private var currentText = ""
    private var inAuthor = false
    private var inEntry = false
    private var finished = false

    func parse(_ data: Data) -> ArxivEntry? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { return nil }
        let hasContent = entry.title != nil || !entry.authors.isEmpty || entry.year != nil
        return hasContent ? entry : nil
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        currentElement = elementName
        currentText = ""
        if elementName == "entry" {
            inEntry = true
        }
        if elementName == "author" {
            inAuthor = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard !finished else { return }
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "title":
            // The feed's own outer <title> is the query echo; only the title
            // inside an <entry> is the paper's title.
            if inEntry, entry.title == nil, !text.isEmpty {
                entry.title = text
            }
        case "name":
            if inAuthor, !text.isEmpty {
                entry.authors.append(text)
            }
        case "author":
            inAuthor = false
        case "published":
            if entry.year == nil, text.count >= 4, let year = Int(text.prefix(4)) {
                entry.year = year
            }
        case "arxiv:journal_ref", "journal_ref":
            if !text.isEmpty { entry.journalRef = text }
        case "arxiv:doi", "doi":
            if !text.isEmpty { entry.doi = text }
        case "entry":
            // Stop after the first entry so a multi-result feed can't clobber.
            finished = true
        default:
            break
        }
        currentText = ""
    }
}
