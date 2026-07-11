import SwiftUI
import AppKit
import PaperReaderCore

/// A single card in the Home grid (spec §3 Phase 1, extended in Session 5 Part
/// A): thumbnail, title, page count, and tag chips for one imported `Paper`.
/// The whole card reports `.contentShape(Rectangle())` so a parent view can
/// attach tap/selection handling over its full bounds. The card is also a drag
/// source (`"paper:<id>"`) so it can be dropped onto a sidebar notebook.
struct PaperCardView: View {
    let paper: Paper
    let papersDirectory: URL
    @ObservedObject var library: LibraryViewModel
    /// Whether this card is part of the click-to-select selection (Session
    /// 11); drives the accent border/tint. Defaults to false for previews
    /// and any caller that doesn't participate in selection.
    var isSelected: Bool = false
    /// The full current multi-selection (Session 11), used only to decide
    /// whether this card's "Delete…" context-menu action should target the
    /// whole selection or just this one paper.
    var selectedIDs: Set<String> = []
    /// Invoked with the id(s) to delete when the user chooses "Delete
    /// Paper…"/"Delete N Papers…" from the context menu; the caller (the
    /// home grid) owns the confirmation alert.
    var onRequestDelete: (Set<String>) -> Void = { _ in }

    @State private var isEditingTags = false
    @State private var newTagText = ""
    @State private var isConfirmingDeleteNote = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    init(
        paper: Paper,
        papersDirectory: URL,
        library: LibraryViewModel,
        isSelected: Bool = false,
        selectedIDs: Set<String> = [],
        onRequestDelete: @escaping (Set<String>) -> Void = { _ in }
    ) {
        self.paper = paper
        self.papersDirectory = papersDirectory
        self.library = library
        self.isSelected = isSelected
        self.selectedIDs = selectedIDs
        self.onRequestDelete = onRequestDelete
    }

    /// The ids a context-menu "Delete…" on this card should act on: the whole
    /// current selection if this card is part of a multi-card selection,
    /// otherwise just this card's own paper.
    private var idsToDelete: Set<String> {
        (isSelected && selectedIDs.count > 1) ? selectedIDs : [paper.id]
    }

    private static let cardWidth: CGFloat = 160
    private static let thumbnailHeight: CGFloat = 200

    private var tags: [Tag] {
        library.tagsByPaper[paper.id] ?? []
    }

    private var hasNotes: Bool {
        library.papersWithNotes.contains(paper.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                thumbnailView
                    .frame(width: Self.cardWidth, height: Self.thumbnailHeight)

                HStack(spacing: 4) {
                    ReadingStatusBadge(status: ReadingStatus(rawValueOrUnread: paper.readingStatus))
                    if hasNotes { PaperNoteBadge() }
                }
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                HStack(spacing: 6) {
                    openNoteButton
                    tagEditButton
                }
                .padding(6)
            }

            Text(paper.title ?? "Untitled")
                .font(.headline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let count = paper.pageCount {
                Text(count == 1 ? "1 page" : "\(count) pages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !tags.isEmpty {
                tagChipsRow
            }
        }
        .padding(12)
        .frame(width: Self.cardWidth + 24)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: isSelected ? 2.5 : 1)
        )
        .contentShape(Rectangle())
        .draggable("paper:\(paper.id)")
        .contextMenu {
            Button(paper.pinnedAt == nil ? "Pin" : "Unpin") {
                library.setPaperPinned(paperId: paper.id, pinned: paper.pinnedAt == nil)
            }
            Menu("Reading Status") {
                ForEach(ReadingStatus.allCases) { status in
                    Button {
                        library.setReadingStatus(paperId: paper.id, status: status)
                    } label: {
                        Label(status.label, systemImage: status.symbol)
                    }
                }
            }
            Button("Edit Tags…") {
                isEditingTags = true
            }
            Button("Open Note") {
                openNote()
            }
            Button("Delete Note…", role: .destructive) {
                isConfirmingDeleteNote = true
            }
            Divider()
            Button(idsToDelete.count > 1 ? "Delete \(idsToDelete.count) Papers…" : "Delete Paper…", role: .destructive) {
                onRequestDelete(idsToDelete)
            }
        }
        .alert("Delete this note?", isPresented: $isConfirmingDeleteNote) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                _ = try? NoteRepository(database: library.database).deletePrimaryNote(forPaper: paper.id)
                library.reloadPapers()
                dismissWindow(value: NotesWindowID(paperId: paper.id))
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    /// A small, non-tap-through control that opens (or lazily creates) the
    /// paper's primary note in the existing detached notes window (spec
    /// Session 7 Part A, #5). `openWindow(value:)` brings an already-open
    /// window for the same `NotesWindowID` to the front instead of duplicating
    /// it, so this single call both creates-and-opens and "reveals if open".
    private var openNoteButton: some View {
        Button {
            openNote()
        } label: {
            Image(systemName: "note.text")
                .font(.caption)
                .padding(6)
                .background(Circle().fill(.ultraThinMaterial))
        }
        .buttonStyle(.plain)
        .help("Open Note")
    }

    private func openNote() {
        openWindow(value: NotesWindowID(paperId: paper.id))
    }

    /// A small, non-tap-through control that opens the tag editor popover
    /// without triggering the card's parent Button (used to open the reader).
    private var tagEditButton: some View {
        Button {
            isEditingTags = true
        } label: {
            Image(systemName: "tag")
                .font(.caption)
                .padding(6)
                .background(Circle().fill(.ultraThinMaterial))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isEditingTags) {
            tagEditorPopover
        }
    }

    @ViewBuilder
    private var tagChipsRow: some View {
        FlowLayout(spacing: 4) {
            ForEach(tags) { tag in
                Text(tag.name)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
        }
    }

    private var tagEditorPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tags")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            if tags.isEmpty {
                Text("No tags yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 4) {
                    ForEach(tags) { tag in
                        HStack(spacing: 4) {
                            Text(tag.name)
                                .font(.caption)
                            Button {
                                library.removeTag(tagId: tag.id, fromPaper: paper.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
            }

            TextField("Add tag", text: $newTagText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submitNewTag)

            if !tagSuggestions.isEmpty || tagCreateSuggestionName != nil {
                tagAutocompleteDropdown
            }
        }
        .padding(12)
        .frame(width: 220)
    }

    /// Existing tags (not already on this paper) whose name contains the
    /// typed text, case-insensitively (Session 11 tag autocomplete).
    private var tagSuggestions: [Tag] {
        let query = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let assignedIds = Set(tags.map(\.id))
        return library.allTags.filter { tag in
            !assignedIds.contains(tag.id) && tag.name.localizedCaseInsensitiveContains(query)
        }
    }

    /// The trimmed typed text, if non-empty and not already an existing tag
    /// name — offered as a "Create "<text>"" row so the user can always add a
    /// genuinely new tag alongside picking an existing one.
    private var tagCreateSuggestionName: String? {
        let query = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let alreadyExists = library.allTags.contains { $0.name.caseInsensitiveCompare(query) == .orderedSame }
        return alreadyExists ? nil : query
    }

    @ViewBuilder
    private var tagAutocompleteDropdown: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(tagSuggestions) { tag in
                    Button {
                        library.addTag(name: tag.name, toPaper: paper.id)
                        newTagText = ""
                    } label: {
                        Text(tag.name)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.plain)
                }

                if let createName = tagCreateSuggestionName {
                    Button {
                        library.addTag(name: createName, toPaper: paper.id)
                        newTagText = ""
                    } label: {
                        Text("Create \u{201C}\(createName)\u{201D}")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 100)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.secondary.opacity(0.08)))
    }

    /// Commits the typed text as a tag on Enter — always via `addTag`
    /// (find-or-create), so pressing Enter works the same whether the text
    /// matches an existing tag or is brand new.
    private func submitNewTag() {
        let name = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        library.addTag(name: name, toPaper: paper.id)
        newTagText = ""
    }

    /// The cached page-1 thumbnail if it exists on disk, otherwise a placeholder icon.
    @ViewBuilder
    private var thumbnailView: some View {
        if let nsImage = loadThumbnailImage() {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .overlay(
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                )
        }
    }

    private func loadThumbnailImage() -> NSImage? {
        let url = PDFImportService.thumbnailURL(for: paper, in: papersDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }
}
