import Foundation
import PaperReaderCore

@MainActor
final class PageBookmarkStore: ObservableObject {
    @Published private(set) var bookmarkedPages: Set<Int> = []

    private let paperId: String
    private let repository: PageBookmarkRepository

    init(paperId: String, repository: PageBookmarkRepository) {
        self.paperId = paperId
        self.repository = repository
    }

    func load() {
        if let pages = try? repository.bookmarkedPages(forPaper: paperId) {
            bookmarkedPages = pages
        }
    }

    func toggle(page: Int) {
        guard let isBookmarked = try? repository.toggle(paperId: paperId, page: page) else {
            return
        }

        if isBookmarked {
            bookmarkedPages.insert(page)
        } else {
            bookmarkedPages.remove(page)
        }
    }
}
