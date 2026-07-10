import Foundation
import SwiftUI
import PaperReaderCore

/// Drives the detached notes window for a single paper: loads (or lazily
/// creates) the paper's primary note, debounces autosave of edits, and lets
/// the user insert clickable references to the paper's highlights (spec §4).
@MainActor
final class NotesViewModel: ObservableObject {
    /// The note's markdown source, bound to the raw editor.
    @Published var body: String = ""
    /// Ids of highlights referenced from `body`, persisted alongside it.
    @Published private(set) var linkedHighlightIds: [String] = []
    /// All highlights for this paper, offered in the "Insert Reference" menu.
    @Published private(set) var highlights: [Highlight] = []

    let paperId: String
    let paperTitle: String

    private let noteRepo: NoteRepository
    private let highlightRepo: HighlightRepository
    /// `lazy` so the `[weak self]` closure below can be wired up without
    /// referencing `self` before all other stored properties are initialized.
    private lazy var autosave: AutosaveController = AutosaveController(debounce: 1.5) { [weak self] in
        self?.saveNow()
    }
    private var note: Note?

    init(paperId: String, paperTitle: String, database: DatabaseManager) {
        self.paperId = paperId
        self.paperTitle = paperTitle
        self.noteRepo = NoteRepository(database: database)
        self.highlightRepo = HighlightRepository(database: database)
    }

    /// Load (or lazily create) the paper's primary note + its highlights.
    func load() {
        let loaded = try? noteRepo.loadOrCreatePrimaryNote(forPaper: paperId, title: "Notes — \(paperTitle)")
        note = loaded
        body = loaded?.body ?? ""
        linkedHighlightIds = NoteRepository.decodeLinkedIds(loaded?.linkedHighlightIds)
        highlights = (try? highlightRepo.highlights(forPaper: paperId)) ?? []
    }

    /// Call on every body edit — schedules a debounced autosave.
    func onBodyEdited() {
        autosave.schedule()
    }

    /// Save immediately if a save is pending (call when the window closes).
    func flushSave() {
        autosave.flush()
    }

    /// Append a markdown reference to `highlight` to the note body and record its id.
    func insertReference(to highlight: Highlight) {
        let snippet = shortSnippet(from: highlight.selectedText)
        let url = HighlightLink.url(highlightId: highlight.id, pageIndex: highlight.page)
        let md = "[p.\(highlight.page + 1): \"\(snippet)\"](\(url.absoluteString))"

        if !body.isEmpty && !body.hasSuffix("\n") {
            body += "\n"
        }
        body += md + "\n"

        if !linkedHighlightIds.contains(highlight.id) {
            linkedHighlightIds.append(highlight.id)
        }

        onBodyEdited()
    }

    /// Persists the current body / linked highlight ids to the loaded note.
    private func saveNow() {
        guard var n = note else { return }
        n.body = body
        n.linkedHighlightIds = NoteRepository.encodeLinkedIds(linkedHighlightIds)
        try? noteRepo.save(n)
        note = n
    }

    /// Collapses `text` to a single line and truncates it to ~60 characters.
    private func shortSnippet(from text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > 60 else { return collapsed }
        return String(collapsed.prefix(60)) + "…"
    }
}
