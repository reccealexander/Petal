import Foundation
import SwiftUI
import PaperReaderCore

/// Which papers the home grid shows.
enum LibrarySelection: Hashable {
    case all
    case unfiled
    case notebook(String)   // notebook id
}

/// How the "All Papers" detail groups the current `papers` list (Session 7
/// Part A, #4). Grouping is orthogonal to `selection`/tag filters — it just
/// changes how whatever papers already passed those filters are presented.
enum PaperGrouping: String, CaseIterable {
    case flat
    case byNotebook
    case byTag

    var label: String {
        switch self {
        case .flat: return "Flat"
        case .byNotebook: return "By Notebook"
        case .byTag: return "By Tag"
        }
    }
}

/// Home-screen "brain": coordinates notebooks, tags, search, selection and
/// the filtered paper list for `HomeView`, going through the Core
/// repositories rather than touching the database directly (spec §1).
@MainActor
final class LibraryViewModel: ObservableObject {
    /// The full notebook tree (flat list; callers derive structure via `childNotebooks(of:)`).
    @Published private(set) var notebooks: [Notebook] = []
    /// Every tag in the library, for the filter UI.
    @Published private(set) var allTags: [Tag] = []
    /// Papers matching the current `selection` and `activeTagIds`.
    @Published private(set) var papers: [Paper] = []
    /// Tags of each paper in `papers`, keyed by paper id (for card chips).
    @Published private(set) var tagsByPaper: [String: [Tag]] = [:]
    /// The current home-grid scope. Changing this reloads `papers`.
    @Published var selection: LibrarySelection = .all { didSet { reloadPapers() } }
    /// Tag ids currently filtering the grid (AND semantics — see `reloadPapers`).
    @Published private(set) var activeTagIds: Set<String> = []
    /// Raw text bound to the search field.
    @Published var searchText: String = ""
    /// Results of the last `runSearch()` call.
    @Published private(set) var searchResults: [SearchResult] = []
    /// How the papers detail groups the current `papers` (Session 7 Part A, #4).
    @Published var grouping: PaperGrouping = .flat

    /// Whether `searchText` has any non-whitespace content.
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    let database: DatabaseManager
    private let notebookRepo: NotebookRepository
    private let tagRepo: TagRepository
    private let searchRepo: SearchRepository
    /// Token for the `.notebookSummaryDidUpdate` observer, so an
    /// async-generated notebook summary (Session 10, Feature 3) refreshes
    /// `notebooks` — and therefore `HomeView`'s summary header — once it lands.
    private var summaryUpdateObserver: NSObjectProtocol?

    /// Creates the view model and its repositories from `database`, then loads
    /// the initial notebook/tag/paper state.
    init(database: DatabaseManager) {
        self.database = database
        self.notebookRepo = NotebookRepository(database: database)
        self.tagRepo = TagRepository(database: database)
        self.searchRepo = SearchRepository(database: database)
        refresh()

        // Mirrors `CompareCoordinator`'s notification-observer pattern: the
        // closure is `@Sendable` (implicitly, per `addObserver`'s `using:`
        // parameter), so the actual main-actor work happens inside
        // `MainActor.assumeIsolated`, which is sound here because `queue: .main`
        // guarantees the closure only ever runs on the main thread.
        summaryUpdateObserver = NotificationCenter.default.addObserver(
            forName: .notebookSummaryDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadNotebooks()
            }
        }
    }

    // No `deinit` removing `summaryUpdateObserver`: `LibraryViewModel` lives
    // for the whole lifetime of the Home window (it's the `@StateObject` at
    // the top of `LibraryContentView`), and a `@MainActor` class's `deinit`
    // runs nonisolated, so it can't touch the (non-Sendable) observer token
    // synchronously anyway. The token is retained only so a future caller
    // that *does* need to unregister early has it available.

    // MARK: - Loading

    /// Reloads notebooks, tags and the filtered paper list, in that order.
    func refresh() {
        reloadNotebooks()
        reloadTags()
        reloadPapers()
    }

    /// Reloads `notebooks` from the repository.
    func reloadNotebooks() {
        notebooks = (try? notebookRepo.allNotebooks()) ?? []
    }

    /// Reloads `allTags` from the repository.
    func reloadTags() {
        allTags = (try? tagRepo.allTags()) ?? []
    }

    /// Recomputes `papers` for the current `selection`, narrowed by
    /// `activeTagIds` (a paper must carry every selected tag), and rebuilds
    /// `tagsByPaper` for the resulting set.
    func reloadPapers() {
        let base: [Paper]
        switch selection {
        case .all:
            base = (try? notebookRepo.allPapers()) ?? []
        case .unfiled:
            base = (try? notebookRepo.unfiledPapers()) ?? []
        case .notebook(let id):
            base = (try? notebookRepo.papersUnder(notebookId: id)) ?? []
        }

        var filtered = base
        if !activeTagIds.isEmpty {
            var matchingIds: Set<String>?
            for tagId in activeTagIds {
                let idsForTag = (try? tagRepo.paperIds(withTag: tagId)) ?? []
                if let existing = matchingIds {
                    matchingIds = existing.intersection(idsForTag)
                } else {
                    matchingIds = idsForTag
                }
            }
            let allowed = matchingIds ?? []
            filtered = base.filter { allowed.contains($0.id) }
        }

        papers = filtered
        var tagsMap: [String: [Tag]] = [:]
        for paper in filtered {
            tagsMap[paper.id] = (try? tagRepo.tags(forPaper: paper.id)) ?? []
        }
        tagsByPaper = tagsMap
    }

    // MARK: - Notebooks

    /// Notebooks whose `parentId` equals `parentId` (already sorted by `allNotebooks()`).
    func childNotebooks(of parentId: String?) -> [Notebook] {
        notebooks.filter { $0.parentId == parentId }
    }

    /// Creates a new notebook and reloads the notebook tree.
    func createNotebook(name: String, parentId: String?) {
        _ = try? notebookRepo.create(name: name, parentId: parentId)
        reloadNotebooks()
    }

    /// Renames a notebook and reloads the notebook tree.
    func renameNotebook(id: String, to newName: String) {
        try? notebookRepo.rename(id: id, to: newName)
        reloadNotebooks()
    }

    /// Deletes a notebook. If it was the active selection, falls back to `.all`
    /// (which reloads papers via `didSet`); reloads notebooks and papers either way.
    func deleteNotebook(id: String) {
        try? notebookRepo.delete(id: id)
        if selection == .notebook(id) {
            selection = .all
        }
        reloadNotebooks()
        reloadPapers()
    }

    /// True if `id` or any descendant notebook contains at least one paper
    /// (used to decide whether to confirm before deleting).
    func notebookContainsPapers(id: String) -> Bool {
        (try? notebookRepo.containsPapers(notebookId: id)) ?? false
    }

    /// Re-parents a notebook, silently ignoring `NotebookError.wouldCreateCycle`.
    func moveNotebook(id: String, toParent newParentId: String?) {
        do {
            try notebookRepo.move(id: id, toParent: newParentId)
            reloadNotebooks()
        } catch {
            // NotebookError.wouldCreateCycle (or any other failure): ignore, leave tree unchanged.
        }
    }

    /// Moves a paper into `notebookId` (nil for Unfiled) and reloads the paper list.
    func movePaper(paperId: String, toNotebook notebookId: String?) {
        try? notebookRepo.movePaper(paperId: paperId, toNotebook: notebookId)
        reloadPapers()
    }

    // MARK: - Tags

    /// Creates (or reuses) a tag by name and assigns it to a paper.
    func addTag(name: String, toPaper paperId: String) {
        _ = try? tagRepo.addTag(name: name, toPaper: paperId)
        reloadTags()
        reloadPapers()
    }

    /// Unassigns a tag from a paper (the tag itself is left intact).
    func removeTag(tagId: String, fromPaper paperId: String) {
        try? tagRepo.removeTag(tagId: tagId, fromPaper: paperId)
        reloadTags()
        reloadPapers()
    }

    /// Deletes a tag everywhere and drops it from the active filter.
    func deleteTag(id: String) {
        try? tagRepo.deleteTag(id: id)
        activeTagIds.remove(id)
        reloadTags()
        reloadPapers()
    }

    /// Toggles whether `tagId` narrows the home grid, then reloads papers.
    func toggleTagFilter(_ tagId: String) {
        if activeTagIds.contains(tagId) {
            activeTagIds.remove(tagId)
        } else {
            activeTagIds.insert(tagId)
        }
        reloadPapers()
    }

    /// Whether `tagId` is currently one of the active grid filters.
    func isTagFilterActive(_ tagId: String) -> Bool {
        activeTagIds.contains(tagId)
    }

    // MARK: - Search

    /// Runs a full-text search for `searchText`, storing results in `searchResults`.
    func runSearch() {
        searchResults = (try? searchRepo.search(searchText)) ?? []
    }

    /// The currently-shown paper with the given id, if any.
    func paper(withId id: String) -> Paper? {
        papers.first { $0.id == id }
    }

    // MARK: - Delete (Session 11)

    /// Permanently deletes the papers with the given ids: their DB row (which
    /// cascades highlight/comment/note via FK), any paper-scoped chat
    /// sessions (no FK, so removed explicitly), their search-index rows, and
    /// every file on disk (PDF, cover thumbnail, per-page thumbnails). Leaves
    /// no orphaned rows or files behind.
    func deletePapers(ids: Set<String>) {
        guard !ids.isEmpty else { return }

        // Snapshot the Paper rows first so we still have file paths to clean
        // up after the DB rows are gone.
        let papersToDelete = papers.filter { ids.contains($0.id) }

        try? database.dbQueue.write { db in
            for id in ids {
                try db.execute(
                    sql: "DELETE FROM chat_session WHERE scope = 'paper' AND scope_id = ?",
                    arguments: [id]
                )
                try db.execute(
                    sql: "DELETE FROM search_index WHERE paper_id = ?",
                    arguments: [id]
                )
                try db.execute(sql: "DELETE FROM paper WHERE id = ?", arguments: [id])
            }
        }

        let fileManager = FileManager.default
        let papersDirectory = database.papersDirectory
        for paper in papersToDelete {
            try? fileManager.removeItem(at: PDFImportService.fileURL(for: paper, in: papersDirectory))
            try? fileManager.removeItem(at: PDFImportService.thumbnailURL(for: paper, in: papersDirectory))

            let pagePrefix = "\(paper.id)_page_"
            if let contents = try? fileManager.contentsOfDirectory(at: papersDirectory, includingPropertiesForKeys: nil) {
                for fileURL in contents where fileURL.lastPathComponent.hasPrefix(pagePrefix) {
                    try? fileManager.removeItem(at: fileURL)
                }
            }
        }

        reloadPapers()
    }

    // MARK: - Grouping (Session 7 Part A, #4)

    /// Groups `papers` per `grouping`, preserving `papers`' order within each
    /// group. `.flat` returns a single unnamed group with every paper.
    func groupedPapers() -> [(title: String, papers: [Paper])] {
        switch grouping {
        case .flat:
            return [(title: "", papers: papers)]
        case .byNotebook:
            return groupedByNotebook()
        case .byTag:
            return groupedByTag()
        }
    }

    /// Groups by `notebookId`, using the notebook's name as the group title.
    /// Papers with no notebook are collected under "No Notebook", sorted last.
    private func groupedByNotebook() -> [(title: String, papers: [Paper])] {
        var order: [String] = []          // notebook ids in first-seen order
        var byNotebook: [String: [Paper]] = [:]
        var unfiled: [Paper] = []

        for paper in papers {
            guard let notebookId = paper.notebookId else {
                unfiled.append(paper)
                continue
            }
            if byNotebook[notebookId] == nil {
                order.append(notebookId)
                byNotebook[notebookId] = []
            }
            byNotebook[notebookId]?.append(paper)
        }

        var groups = order.map { id in
            (title: notebooks.first(where: { $0.id == id })?.name ?? "Notebook", papers: byNotebook[id] ?? [])
        }
        if !unfiled.isEmpty {
            groups.append((title: "No Notebook", papers: unfiled))
        }
        return groups
    }

    /// Groups by tag; a paper with multiple tags appears under each tag's
    /// group. Papers with no tags are collected under "Untagged", sorted last.
    private func groupedByTag() -> [(title: String, papers: [Paper])] {
        var order: [String] = []          // tag ids in first-seen order
        var byTag: [String: [Paper]] = [:]
        var tagNames: [String: String] = [:]
        var untagged: [Paper] = []

        for paper in papers {
            let tags = tagsByPaper[paper.id] ?? []
            if tags.isEmpty {
                untagged.append(paper)
                continue
            }
            for tag in tags {
                if byTag[tag.id] == nil {
                    order.append(tag.id)
                    byTag[tag.id] = []
                    tagNames[tag.id] = tag.name
                }
                byTag[tag.id]?.append(paper)
            }
        }

        var groups = order.map { id in
            (title: tagNames[id] ?? "Tag", papers: byTag[id] ?? [])
        }
        if !untagged.isEmpty {
            groups.append((title: "Untagged", papers: untagged))
        }
        return groups
    }
}
