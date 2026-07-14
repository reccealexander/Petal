import Foundation

/// A citation output style. `displayName` is shown in the picker; `rawValue`
/// doubles as a stable identifier for persistence if ever needed.
public enum CitationStyle: String, CaseIterable, Identifiable, Sendable {
    case apa = "APA"
    case mla = "MLA"
    case chicago = "Chicago"
    case bibtex = "BibTeX"
    case ris = "RIS"

    public var id: String { rawValue }
    public var displayName: String { rawValue }
}

/// One author decomposed into name components. `given` may itself hold
/// multiple given names ("John Michael") or pre-abbreviated initials
/// ("J. M."); the formatters normalise it per style. `family` is required.
public struct CitationAuthor: Equatable, Sendable {
    public var given: String?
    public var family: String

    public init(given: String? = nil, family: String) {
        self.given = given?.isEmpty == true ? nil : given
        self.family = family
    }

    /// Parses a free-text author string (as stored on `Paper.authors`) into a
    /// list of authors. Handles the common separators used by PDF metadata and
    /// citation managers: ";", " and ", " & ", and plain comma-separated lists.
    /// Each individual name may be "First Last" or "Last, First".
    public static func parse(from freeText: String?) -> [CitationAuthor] {
        guard let raw = freeText?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return []
        }

        // Normalise the ampersand form of "and" so we have one delimiter set.
        let normalized = raw
            .replacingOccurrences(of: " & ", with: " and ")

        let chunks: [String]
        if normalized.contains(";") {
            chunks = normalized.components(separatedBy: ";")
        } else if normalized.range(of: #"\s+and\s+"#, options: .regularExpression) != nil {
            // Split on the word "and" (surrounded by whitespace) into authors.
            let marked = normalized.replacingOccurrences(
                of: #"\s+and\s+"#, with: "\u{1}", options: .regularExpression
            )
            chunks = marked.components(separatedBy: "\u{1}")
        } else if normalized.contains(",") {
            chunks = splitCommaSeparatedNames(normalized)
        } else {
            chunks = [normalized]
        }

        return chunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(parseSingleName)
    }

    /// Splits a comma-only author string. Distinguishes a single inverted name
    /// ("Smith, John" / "Smith, J.") from a comma-separated list of full names
    /// ("John Smith, Jane Doe"). If there are exactly two parts and the second
    /// looks like given names/initials, it is treated as one inverted name.
    private static func splitCommaSeparatedNames(_ text: String) -> [String] {
        let parts = text.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        // Single inverted name ("Smith, John") only when the pre-comma part is a
        // lone family token and the post-comma part reads like given names. A
        // multi-word first part ("John Smith, Jane Doe") is a list of names.
        if parts.count == 2,
           !parts[0].contains(" "),
           looksLikeGivenNames(parts[1]) {
            return [text]
        }
        return parts
    }

    /// Whether a token reads like given names or initials (short, no numbers),
    /// used to detect the "Last, First" single-author shape.
    private static func looksLikeGivenNames(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        let words = token.split(separator: " ")
        guard words.count <= 3 else { return false }
        return words.allSatisfy { word in
            let bare = word.replacingOccurrences(of: ".", with: "")
            return bare.count <= 12 && bare.allSatisfy { $0.isLetter }
        }
    }

    /// Parses one name into components. "Last, First" (comma) inverts; a plain
    /// "First Middle Last" takes the final token as the family name.
    private static func parseSingleName(_ name: String) -> CitationAuthor {
        if let commaIndex = name.firstIndex(of: ",") {
            let family = String(name[..<commaIndex]).trimmingCharacters(in: .whitespaces)
            let given = String(name[name.index(after: commaIndex)...]).trimmingCharacters(in: .whitespaces)
            return CitationAuthor(given: given.isEmpty ? nil : given, family: family)
        }

        let tokens = name.split(separator: " ").map(String.init)
        guard tokens.count > 1 else {
            return CitationAuthor(given: nil, family: name)
        }
        let family = tokens.last!
        let given = tokens.dropLast().joined(separator: " ")
        return CitationAuthor(given: given, family: family)
    }

    /// Full initials for the given names, e.g. "John Michael" -> "J. M." and
    /// "J.M." -> "J. M.". Empty string when there is no given name.
    var initials: String {
        guard let given else { return "" }
        // Split on spaces and periods so pre-abbreviated forms normalise too.
        let pieces = given
            .replacingOccurrences(of: ".", with: " ")
            .split(separator: " ")
        return pieces.compactMap { $0.first }.map { "\($0)." }.joined(separator: " ")
    }

    /// "Given Family" (natural reading order); falls back to family alone.
    var displayNatural: String {
        guard let given, !given.isEmpty else { return family }
        return "\(given) \(family)"
    }
}

/// Structured, style-agnostic citation input. Built from a `Paper` and
/// optionally enriched from CrossRef/arXiv. Every field beyond the author list
/// and title is optional so citations degrade gracefully when metadata is thin.
public struct CitationMetadata: Equatable, Sendable {
    public var authors: [CitationAuthor]
    public var title: String?
    public var year: Int?
    /// Journal / conference / venue name.
    public var container: String?
    public var publisher: String?
    public var volume: String?
    public var issue: String?
    public var pages: String?
    public var doi: String?
    public var arxivId: String?

    public init(
        authors: [CitationAuthor] = [],
        title: String? = nil,
        year: Int? = nil,
        container: String? = nil,
        publisher: String? = nil,
        volume: String? = nil,
        issue: String? = nil,
        pages: String? = nil,
        doi: String? = nil,
        arxivId: String? = nil
    ) {
        self.authors = authors
        self.title = title
        self.year = year
        self.container = container
        self.publisher = publisher
        self.volume = volume
        self.issue = issue
        self.pages = pages
        self.doi = doi
        self.arxivId = arxivId
    }

    /// Assembles metadata from the app's stored `Paper`, parsing the free-text
    /// author string into components. This is the always-available offline
    /// baseline; the async enrichment service overlays richer fields on top.
    public init(paper: Paper) {
        self.init(
            authors: CitationAuthor.parse(from: paper.authors),
            title: paper.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            doi: paper.doi?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            arxivId: paper.arxivId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    /// A canonical URL for the work: DOI takes precedence, then arXiv.
    var canonicalURL: String? {
        if let doi, !doi.isEmpty {
            return "https://doi.org/\(doi)"
        }
        if let arxivId, !arxivId.isEmpty {
            return "https://arxiv.org/abs/\(arxivId)"
        }
        return nil
    }
}

/// Deterministic, offline citation string generator. Pure formatting logic —
/// no I/O — so it is fully unit-testable.
public enum CitationFormatter {
    public static func format(_ metadata: CitationMetadata, style: CitationStyle) -> String {
        switch style {
        case .apa: return apa(metadata)
        case .mla: return mla(metadata)
        case .chicago: return chicago(metadata)
        case .bibtex: return bibtex(metadata)
        case .ris: return ris(metadata)
        }
    }

    // MARK: - Title helpers

    /// Title with a single terminal period, avoiding doubling when the title
    /// already ends in sentence punctuation.
    private static func titleWithPeriod(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if let last = trimmed.last, ".!?".contains(last) {
            return trimmed
        }
        return trimmed + "."
    }

    // MARK: - APA (7th edition)

    private static func apa(_ m: CitationMetadata) -> String {
        var parts: [String] = []

        let authorList = apaAuthors(m.authors)
        if !authorList.isEmpty {
            parts.append(authorList.hasSuffix(".") ? authorList : authorList + ".")
        }

        if let year = m.year {
            parts.append("(\(year)).")
        }

        if let title = m.title {
            parts.append(titleWithPeriod(title))
        }

        if let container = m.container, !container.isEmpty {
            var journal = "*\(container)*"
            if let volume = m.volume, !volume.isEmpty {
                journal += ", *\(volume)*"
                if let issue = m.issue, !issue.isEmpty {
                    journal += "(\(issue))"
                }
            }
            if let pages = m.pages, !pages.isEmpty {
                journal += ", \(pages)"
            }
            parts.append(journal + ".")
        } else if m.container == nil, m.arxivId != nil {
            parts.append("*arXiv preprint*.")
        }

        if let url = m.canonicalURL {
            parts.append(url)
        }

        return parts.joined(separator: " ")
    }

    /// APA author list: "Family, I. N." inverted, "&" before the final author,
    /// ellipsis for 21+ authors (APA 7 lists the first 19 then the last).
    private static func apaAuthors(_ authors: [CitationAuthor]) -> String {
        let names = authors.map { author -> String in
            author.initials.isEmpty ? author.family : "\(author.family), \(author.initials)"
        }
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]), & \(names[1])"
        case 3...20:
            return names.dropLast().joined(separator: ", ") + ", & " + names.last!
        default:
            return names.prefix(19).joined(separator: ", ") + ", … " + names.last!
        }
    }

    // MARK: - MLA (9th edition)

    private static func mla(_ m: CitationMetadata) -> String {
        var result = ""

        let authorList = mlaAuthors(m.authors)
        if !authorList.isEmpty {
            result += authorList.hasSuffix(".") ? authorList + " " : authorList + ". "
        }

        if let title = m.title {
            result += "\u{201C}\(titleWithPeriod(title))\u{201D} "
        }

        var tail: [String] = []
        if let container = m.container, !container.isEmpty {
            tail.append("*\(container)*")
        }
        if let volume = m.volume, !volume.isEmpty {
            tail.append("vol. \(volume)")
        }
        if let issue = m.issue, !issue.isEmpty {
            tail.append("no. \(issue)")
        }
        if let year = m.year {
            tail.append("\(year)")
        }
        if let pages = m.pages, !pages.isEmpty {
            tail.append("pp. \(pages)")
        }
        if !tail.isEmpty {
            result += tail.joined(separator: ", ") + "."
        }
        if let url = m.canonicalURL {
            result += result.hasSuffix(" ") ? url : " " + url + "."
        }

        return result.trimmingCharacters(in: .whitespaces)
    }

    /// MLA author list: first author inverted "Family, Given", second author in
    /// natural order, "et al." for three or more.
    private static func mlaAuthors(_ authors: [CitationAuthor]) -> String {
        guard let first = authors.first else { return "" }
        let inverted = invertedName(first)
        switch authors.count {
        case 1:
            return inverted
        case 2:
            return "\(inverted), and \(authors[1].displayNatural)"
        default:
            return "\(inverted), et al"
        }
    }

    // MARK: - Chicago (17th, notes-bibliography style)

    private static func chicago(_ m: CitationMetadata) -> String {
        var parts: [String] = []

        let authorList = chicagoAuthors(m.authors)
        if !authorList.isEmpty {
            parts.append(authorList.hasSuffix(".") ? authorList : authorList + ".")
        }

        if let title = m.title {
            parts.append("\u{201C}\(titleWithPeriod(title))\u{201D}")
        }

        var venue = ""
        if let container = m.container, !container.isEmpty {
            venue = "*\(container)*"
            if let volume = m.volume, !volume.isEmpty {
                venue += " \(volume)"
                if let issue = m.issue, !issue.isEmpty {
                    venue += ", no. \(issue)"
                }
            }
            if let year = m.year {
                venue += " (\(year))"
            }
            if let pages = m.pages, !pages.isEmpty {
                venue += ": \(pages)"
            }
            parts.append(venue + ".")
        } else if let year = m.year {
            parts.append("\(year).")
        }

        if let url = m.canonicalURL {
            parts.append(url + ".")
        }

        return parts.joined(separator: " ")
    }

    /// Chicago bibliography author list: first inverted, remaining natural,
    /// "and" before the last, "et al." beyond ten authors.
    private static func chicagoAuthors(_ authors: [CitationAuthor]) -> String {
        guard let first = authors.first else { return "" }
        let inverted = invertedName(first)
        if authors.count == 1 {
            return inverted
        }
        if authors.count > 10 {
            return "\(inverted), et al"
        }
        let rest = authors.dropFirst().map { $0.displayNatural }
        if rest.count == 1 {
            return "\(inverted), and \(rest[0])"
        }
        return "\(inverted), " + rest.dropLast().joined(separator: ", ") + ", and " + rest.last!
    }

    // MARK: - BibTeX

    private static func bibtex(_ m: CitationMetadata) -> String {
        let entryType = (m.container != nil) ? "article" : (m.arxivId != nil ? "misc" : "misc")
        let key = bibtexKey(m)

        var fields: [(String, String)] = []
        if !m.authors.isEmpty {
            let authorField = m.authors.map { author -> String in
                author.given.map { "\(author.family), \($0)" } ?? author.family
            }.joined(separator: " and ")
            fields.append(("author", authorField))
        }
        if let title = m.title {
            fields.append(("title", title))
        }
        if let container = m.container, !container.isEmpty {
            fields.append(("journal", container))
        }
        if let year = m.year {
            fields.append(("year", "\(year)"))
        }
        if let volume = m.volume, !volume.isEmpty {
            fields.append(("volume", volume))
        }
        if let issue = m.issue, !issue.isEmpty {
            fields.append(("number", issue))
        }
        if let pages = m.pages, !pages.isEmpty {
            fields.append(("pages", pages))
        }
        if let publisher = m.publisher, !publisher.isEmpty {
            fields.append(("publisher", publisher))
        }
        if let doi = m.doi, !doi.isEmpty {
            fields.append(("doi", doi))
        }
        if let arxivId = m.arxivId, !arxivId.isEmpty {
            fields.append(("eprint", arxivId))
            fields.append(("archivePrefix", "arXiv"))
        }

        let body = fields
            .map { "  \($0.0) = {\(bibtexEscape($0.1))}" }
            .joined(separator: ",\n")
        return "@\(entryType){\(key),\n\(body)\n}"
    }

    /// Escapes a BibTeX `{…}` field value so special characters can't corrupt the
    /// entry: `%` starts a comment (truncating the file), `&`/`$`/`#`/`_` are
    /// LaTeX specials, and raw newlines/braces break parsing.
    private static func bibtexEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\": out += "\\textbackslash{}"
            case "%", "&", "$", "#", "_": out += "\\\(ch)"
            case "{": out += "\\{"
            case "}": out += "\\}"
            case "~": out += "\\textasciitilde{}"
            case "^": out += "\\textasciicircum{}"
            case "\n", "\r": out += " "
            default: out.append(ch)
            }
        }
        return out
    }

    /// Strips CR/LF from an RIS value — the format is line-tagged, so an embedded
    /// newline would produce an untagged continuation line that breaks parsers.
    private static func risValue(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    /// A conventional BibTeX cite key: first author's family name + year +
    /// first significant title word, lowercased and stripped to alphanumerics.
    private static func bibtexKey(_ m: CitationMetadata) -> String {
        var key = ""
        if let family = m.authors.first?.family {
            key += family
        }
        if let year = m.year {
            key += "\(year)"
        }
        if let firstWord = m.title?.split(separator: " ").first {
            key += firstWord
        }
        let filtered = key.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let cleaned = String(String.UnicodeScalarView(filtered)).lowercased()
        return cleaned.isEmpty ? "citation" : cleaned
    }

    // MARK: - RIS

    private static func ris(_ m: CitationMetadata) -> String {
        var lines: [String] = []
        lines.append("TY  - \(m.container != nil ? "JOUR" : "GEN")")
        for author in m.authors {
            let name = author.given.map { "\(author.family), \($0)" } ?? author.family
            lines.append("AU  - \(risValue(name))")
        }
        if let title = m.title {
            lines.append("TI  - \(risValue(title))")
        }
        if let container = m.container, !container.isEmpty {
            lines.append("JO  - \(risValue(container))")
        }
        if let year = m.year {
            lines.append("PY  - \(year)")
        }
        if let volume = m.volume, !volume.isEmpty {
            lines.append("VL  - \(volume)")
        }
        if let issue = m.issue, !issue.isEmpty {
            lines.append("IS  - \(issue)")
        }
        if let pages = m.pages, !pages.isEmpty {
            lines.append("SP  - \(pages)")
        }
        if let doi = m.doi, !doi.isEmpty {
            lines.append("DO  - \(doi)")
        }
        if let url = m.canonicalURL {
            lines.append("UR  - \(url)")
        }
        lines.append("ER  - ")
        return lines.joined(separator: "\n")
    }

    // MARK: - Shared

    /// "Family, Given" for the first/anchor author position.
    private static func invertedName(_ author: CitationAuthor) -> String {
        guard let given = author.given, !given.isEmpty else { return author.family }
        return "\(author.family), \(given)"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
