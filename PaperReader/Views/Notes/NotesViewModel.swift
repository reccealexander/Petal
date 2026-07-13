import Foundation
import SwiftUI
import AppKit
import PaperReaderCore

/// Drives the detached notes window for a single paper: loads (or lazily
/// creates) the paper's primary note, debounces autosave of edits, and lets
/// the user insert clickable references to the paper's highlights (spec §4).
@MainActor
final class NotesViewModel: ObservableObject {
    /// The note's rich-text source, bound to the AppKit editor.
    @Published var attributedText = NSAttributedString(string: "")
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
    /// Set once `deleteNote()` runs so a save already in flight (or a stray
    /// `saveNow()` call) can't resurrect the row after deletion.
    private var deleted = false

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
        if let data = loaded?.bodyRtf,
           let decoded = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil) {
            attributedText = decoded
        } else {
            attributedText = NSAttributedString(string: loaded?.body ?? "")
        }
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

    /// Append a styled, clickable highlight reference and record its id.
    func insertReference(to highlight: Highlight) {
        let snippet = shortSnippet(from: highlight.selectedText)
        let url = HighlightLink.url(highlightId: highlight.id, pageIndex: highlight.page)
        let result = NSMutableAttributedString(attributedString: attributedText)
        if result.length > 0 && !result.string.hasSuffix("\n") {
            result.append(NSAttributedString(string: "\n"))
        }
        let label = "p.\(highlight.page + 1): \"\(snippet)\""
        result.append(NSAttributedString(string: label, attributes: [
            .link: url,
            .foregroundColor: NSColor.controlAccentColor,
            .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.10),
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]))
        result.append(NSAttributedString(string: "\n"))
        attributedText = result

        if !linkedHighlightIds.contains(highlight.id) {
            linkedHighlightIds.append(highlight.id)
        }

        onBodyEdited()
    }

    /// Persists the current body / linked highlight ids to the loaded note.
    private func saveNow() {
        guard !deleted, var n = note else { return }
        n.body = attributedText.string
        n.bodyRtf = attributedText.rtf(
            from: NSRange(location: 0, length: attributedText.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        n.linkedHighlightIds = NoteRepository.encodeLinkedIds(linkedHighlightIds)
        try? noteRepo.save(n)
        note = n
    }

    /// Deletes the currently-loaded note. Cancels any pending autosave first
    /// so the debounced save can't fire afterward and re-insert it.
    func deleteNote() {
        autosave.cancel()
        guard let n = note else { return }
        try? noteRepo.deleteNote(id: n.id)
        deleted = true
        note = nil
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
