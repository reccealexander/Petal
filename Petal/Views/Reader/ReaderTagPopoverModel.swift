import Foundation
import PetalCore

/// Drives the reader toolbar's tag popover (Session 7 Part A, Feature 1):
/// the paper's currently-assigned tags, plus a separate list of
/// AI-recommended tags the user can accept with a click. Keeps all
/// DB/network logic out of the SwiftUI view body.
@MainActor
final class ReaderTagPopoverModel: ObservableObject {
    @Published private(set) var assignedTags: [Tag] = []
    @Published private(set) var suggestions: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    /// Computed (not cached at init) so the Keychain is only read when
    /// something actually accesses this property — i.e. when the tag
    /// popover is presented — rather than on every reader/model init
    /// (which used to trigger a Keychain prompt on every paper open).
    var hasAPIKey: Bool { suggestionService.hasAPIKey }

    private let paper: Paper
    private let tagRepository: TagRepository
    private let suggestionService: TagSuggestionService

    init(paper: Paper, database: DatabaseManager) {
        self.paper = paper
        self.tagRepository = TagRepository(database: database)
        self.suggestionService = TagSuggestionService(database: database)
    }

    /// Loads the paper's currently-assigned tags from the DB.
    func load() {
        assignedTags = (try? tagRepository.tags(forPaper: paper.id)) ?? []
    }

    /// Asks Claude for fresh tag suggestions, filtering out any that
    /// duplicate an already-assigned tag (case-insensitive). No-op (leaves
    /// the "no API key" fallback in place) if no key is configured.
    func refreshSuggestions() async {
        guard hasAPIKey else {
            suggestions = []
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // Build the (paper-dependent) context synchronously on this
            // actor first, then only ever `await` with a plain `String` —
            // `Paper` isn't `Sendable` across module boundaries, so handing
            // it directly into an `async` call here would trip Swift 6
            // strict concurrency (see `TagSuggestionService.suggestTags(for:)`
            // doc comment). Mirrors how `ClaudePanelViewModel` builds its
            // system prompt before awaiting `streamMessage`.
            let context = suggestionService.buildContext(for: paper)
            let raw = try await suggestionService.suggestTags(context: context)
            let assignedNames = Set(assignedTags.map { $0.name.lowercased() })
            suggestions = raw.filter { !assignedNames.contains($0.lowercased()) }
        } catch {
            suggestions = []
            errorMessage = error.localizedDescription
        }
    }

    /// Accepts a recommended tag: creates/reuses the Tag row and assigns it
    /// to the paper via the normal Session-5 tagging system, then refreshes
    /// the assigned list and drops it from the suggestion list.
    func accept(_ name: String) {
        _ = try? tagRepository.addTag(name: name, toPaper: paper.id)
        suggestions.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        load()
    }

    /// Removes an already-assigned tag from this paper.
    func remove(_ tag: Tag) {
        try? tagRepository.removeTag(tagId: tag.id, fromPaper: paper.id)
        load()
    }
}
