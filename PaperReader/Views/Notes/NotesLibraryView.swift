import SwiftUI
import PaperReaderCore

/// How `NotesLibraryView` sorts/groups the note list (spec Session 7 Part A, #6.6/#6.7).
enum NotesSortMode: String, CaseIterable {
    case recent
    case byNotebook
    case byTag
    case byLinkStatus

    var label: String {
        switch self {
        case .recent: return "Recent"
        case .byNotebook: return "By Notebook"
        case .byTag: return "By Tag"
        case .byLinkStatus: return "Linked / Unlinked"
        }
    }
}

/// Drives the top-level "Notes" sidebar section (spec Session 7 Part A, #6):
/// loads every note in the library (paper-linked, notebook-linked, and
/// unlinked), offers creation of any of the three kinds, and groups/sorts the
/// list. Editing itself is delegated to `NoteEditorViewModel`, keyed by note
/// id — the same `Note` model and `NoteRepository` used by the per-paper
/// notes window, no parallel note type.
@MainActor
final class NotesLibraryViewModel: ObservableObject {
    @Published private(set) var notes: [Note] = []
    @Published private(set) var papers: [Paper] = []
    @Published private(set) var notebooks: [Notebook] = []
    @Published var sortMode: NotesSortMode = .recent
    @Published var filterText: String = ""
    @Published var selectedNoteId: String?

    let database: DatabaseManager
    private let noteRepo: NoteRepository
    private let notebookRepo: NotebookRepository
    private let tagRepo: TagRepository

    private var papersById: [String: Paper] = [:]
    private var notebooksById: [String: Notebook] = [:]
    private var tagsByPaper: [String: [Tag]] = [:]

    init(database: DatabaseManager) {
        self.database = database
        self.noteRepo = NoteRepository(database: database)
        self.notebookRepo = NotebookRepository(database: database)
        self.tagRepo = TagRepository(database: database)
        refresh()
    }

    /// Reloads notes, papers and notebooks (and per-paper tags used for the
    /// "By Tag" grouping and row metadata).
    func refresh() {
        notes = (try? noteRepo.allNotes()) ?? []
        papers = (try? notebookRepo.allPapers()) ?? []
        notebooks = (try? notebookRepo.allNotebooks()) ?? []
        papersById = Dictionary(uniqueKeysWithValues: papers.map { ($0.id, $0) })
        notebooksById = Dictionary(uniqueKeysWithValues: notebooks.map { ($0.id, $0) })

        var tagsMap: [String: [Tag]] = [:]
        for paper in papers {
            tagsMap[paper.id] = (try? tagRepo.tags(forPaper: paper.id)) ?? []
        }
        tagsByPaper = tagsMap
    }

    // MARK: - Row metadata (#6.5)

    func paper(for note: Note) -> Paper? {
        note.paperId.flatMap { papersById[$0] }
    }

    func notebook(for note: Note) -> Notebook? {
        note.notebookId.flatMap { notebooksById[$0] }
    }

    func tags(for note: Note) -> [Tag] {
        guard let paperId = note.paperId else { return [] }
        return tagsByPaper[paperId] ?? []
    }

    /// The linked paper id for a note, looked up by note id (used to offer
    /// "Open in Window" for paper-linked notes in the inline editor).
    func paperId(forNoteId noteId: String) -> String? {
        notes.first(where: { $0.id == noteId })?.paperId
    }

    /// The title shown in the list: the note's own title, else a one-line
    /// snippet of its body, else "Untitled note".
    func displayTitle(for note: Note) -> String {
        if let title = note.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        let snippet = note.body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !snippet.isEmpty {
            return snippet.count > 60 ? String(snippet.prefix(60)) + "…" : snippet
        }
        return "Untitled note"
    }

    // MARK: - Filtering + grouping

    /// Notes matching `filterText` against title, body, and the linked
    /// paper's title (case-insensitive substring match).
    private var filteredNotes: [Note] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return notes }
        return notes.filter { note in
            if displayTitle(for: note).localizedCaseInsensitiveContains(query) { return true }
            if note.body.localizedCaseInsensitiveContains(query) { return true }
            if let title = paper(for: note)?.title, title.localizedCaseInsensitiveContains(query) { return true }
            return false
        }
    }

    /// Groups `filteredNotes` per `sortMode`. `.recent` returns one unnamed
    /// group in `allNotes()`'s (most-recently-updated-first) order.
    func groupedNotes() -> [(title: String, notes: [Note])] {
        switch sortMode {
        case .recent:
            return [(title: "", notes: filteredNotes)]
        case .byNotebook:
            return groupedByNotebook()
        case .byTag:
            return groupedByTag()
        case .byLinkStatus:
            return groupedByLinkStatus()
        }
    }

    private func groupedByNotebook() -> [(title: String, notes: [Note])] {
        var order: [String] = []
        var byNotebook: [String: [Note]] = [:]
        var noNotebook: [Note] = []

        for note in filteredNotes {
            guard let notebookId = note.notebookId else {
                noNotebook.append(note)
                continue
            }
            if byNotebook[notebookId] == nil {
                order.append(notebookId)
                byNotebook[notebookId] = []
            }
            byNotebook[notebookId]?.append(note)
        }

        var groups = order.map { id in
            (title: notebooksById[id]?.name ?? "Notebook", notes: byNotebook[id] ?? [])
        }
        if !noNotebook.isEmpty {
            groups.append((title: "No Notebook", notes: noNotebook))
        }
        return groups
    }

    private func groupedByTag() -> [(title: String, notes: [Note])] {
        var order: [String] = []
        var byTag: [String: [Note]] = [:]
        var tagNames: [String: String] = [:]
        var untagged: [Note] = []

        for note in filteredNotes {
            let noteTags = tags(for: note)
            if noteTags.isEmpty {
                untagged.append(note)
                continue
            }
            for tag in noteTags {
                if byTag[tag.id] == nil {
                    order.append(tag.id)
                    byTag[tag.id] = []
                    tagNames[tag.id] = tag.name
                }
                byTag[tag.id]?.append(note)
            }
        }

        var groups = order.map { id in
            (title: tagNames[id] ?? "Tag", notes: byTag[id] ?? [])
        }
        if !untagged.isEmpty {
            groups.append((title: "Untagged", notes: untagged))
        }
        return groups
    }

    /// Separates notes into Paper-linked, Notebook-linked, and Unlinked
    /// sections (spec #6.7). A note linked to both a paper and a notebook is
    /// classed as Paper-linked (the more specific link).
    private func groupedByLinkStatus() -> [(title: String, notes: [Note])] {
        var paperLinked: [Note] = []
        var notebookLinked: [Note] = []
        var unlinked: [Note] = []

        for note in filteredNotes {
            if note.paperId != nil {
                paperLinked.append(note)
            } else if note.notebookId != nil {
                notebookLinked.append(note)
            } else {
                unlinked.append(note)
            }
        }

        var groups: [(title: String, notes: [Note])] = []
        if !paperLinked.isEmpty { groups.append((title: "Paper-linked", notes: paperLinked)) }
        if !notebookLinked.isEmpty { groups.append((title: "Notebook-linked", notes: notebookLinked)) }
        if !unlinked.isEmpty { groups.append((title: "Unlinked", notes: unlinked)) }
        return groups
    }

    // MARK: - Creation (#6.4)

    /// Creates a new note of the requested kind, refreshes the list, and
    /// selects it for editing.
    @discardableResult
    func createNote(paperId: String?, notebookId: String?) -> Note? {
        guard let note = try? noteRepo.createNote(paperId: paperId, notebookId: notebookId, title: nil) else {
            return nil
        }
        refresh()
        selectedNoteId = note.id
        return note
    }

    // MARK: - Deletion

    /// Deletes a note by id and refreshes the list. Highlights/comments the
    /// note referenced are untouched — `NoteRepository.deleteNote` only
    /// removes the `note` row and its `search_index` entry. If the deleted
    /// note was the one open in the editor, clears the selection.
    func deleteNote(id: String) {
        try? noteRepo.deleteNote(id: id)
        if selectedNoteId == id {
            selectedNoteId = nil
        }
        refresh()
    }
}

/// Top-level "Notes" section (spec Session 7 Part A, #6): a sortable/filterable
/// list of every note in the library, a creation menu for the three note
/// kinds, and an inline editor for the selected note.
struct NotesLibraryView: View {
    @StateObject private var viewModel: NotesLibraryViewModel
    /// The id of the note pending a delete confirmation, if any (drives the alert).
    @State private var noteIdPendingDelete: String?

    init(database: DatabaseManager) {
        _viewModel = StateObject(wrappedValue: NotesLibraryViewModel(database: database))
    }

    var body: some View {
        HSplitView {
            noteList
                .frame(minWidth: 260, idealWidth: 320)

            Group {
                if let selectedId = viewModel.selectedNoteId {
                    NoteEditorView(
                        noteId: selectedId,
                        database: viewModel.database,
                        paperId: viewModel.paperId(forNoteId: selectedId)
                    )
                    .id(selectedId)
                } else {
                    placeholder
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Notes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                newNoteMenu
            }
        }
        .onAppear { viewModel.refresh() }
        .alert("Delete this note?", isPresented: Binding(
            get: { noteIdPendingDelete != nil },
            set: { if !$0 { noteIdPendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let id = noteIdPendingDelete {
                    viewModel.deleteNote(id: id)
                }
                noteIdPendingDelete = nil
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        Text("Select a note, or create one.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var noteList: some View {
        VStack(spacing: 0) {
            Picker("Sort", selection: $viewModel.sortMode) {
                ForEach(NotesSortMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            List(selection: $viewModel.selectedNoteId) {
                ForEach(viewModel.groupedNotes(), id: \.title) { group in
                    if group.title.isEmpty {
                        ForEach(group.notes) { note in
                            noteRow(note)
                                .tag(note.id)
                                .contextMenu { deleteMenuItem(for: note) }
                        }
                    } else {
                        Section(group.title) {
                            ForEach(group.notes) { note in
                                noteRow(note)
                                    .tag(note.id)
                                    .contextMenu { deleteMenuItem(for: note) }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if viewModel.notes.isEmpty {
                    Text("No notes yet")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $viewModel.filterText, placement: .sidebar, prompt: "Filter notes")
    }

    @ViewBuilder
    private func noteRow(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(viewModel.displayTitle(for: note))
                .font(.body)
                .lineLimit(1)

            HStack(spacing: 6) {
                if let paper = viewModel.paper(for: note) {
                    Label(paper.title ?? "Untitled", systemImage: "doc")
                } else if let notebook = viewModel.notebook(for: note) {
                    Label(notebook.name, systemImage: "folder")
                } else {
                    Label("Unlinked", systemImage: "note.text")
                }
                Spacer(minLength: 0)
                Text(formattedDate(note.updatedAt ?? note.createdAt))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            let tags = viewModel.tags(for: note)
            if !tags.isEmpty {
                Text(tags.map(\.name).joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private func formattedDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder
    private func deleteMenuItem(for note: Note) -> some View {
        Button(role: .destructive) {
            noteIdPendingDelete = note.id
        } label: {
            Label("Delete Note…", systemImage: "trash")
        }
    }

    /// Menu offering the three note kinds (#6.4): unlinked, linked to a
    /// paper, or linked to a notebook.
    @ViewBuilder
    private var newNoteMenu: some View {
        Menu {
            Button("New Unlinked Note") {
                viewModel.createNote(paperId: nil, notebookId: nil)
            }

            if !viewModel.papers.isEmpty {
                Menu("New Note for Paper") {
                    ForEach(viewModel.papers) { paper in
                        Button(paper.title ?? "Untitled") {
                            viewModel.createNote(paperId: paper.id, notebookId: nil)
                        }
                    }
                }
            }

            if !viewModel.notebooks.isEmpty {
                Menu("New Note for Notebook") {
                    ForEach(viewModel.notebooks) { notebook in
                        Button(notebook.name) {
                            viewModel.createNote(paperId: nil, notebookId: notebook.id)
                        }
                    }
                }
            }
        } label: {
            Label("New Note", systemImage: "square.and.pencil")
        }
    }
}

/// Drives the inline note editor (spec Session 7 Part A, #6): loads a note by
/// id and debounce-autosaves title/body edits via `AutosaveController` and
/// `NoteRepository.save`, mirroring `NotesViewModel`'s per-paper autosave
/// exactly but keyed by note id instead of paper id.
@MainActor
final class NoteEditorViewModel: ObservableObject {
    @Published var title: String = ""
    @Published var body: String = ""

    let noteId: String
    private let noteRepo: NoteRepository
    private var note: Note?
    private lazy var autosave: AutosaveController = AutosaveController(debounce: 1.5) { [weak self] in
        self?.saveNow()
    }

    init(noteId: String, database: DatabaseManager) {
        self.noteId = noteId
        self.noteRepo = NoteRepository(database: database)
    }

    func load() {
        guard let loaded = try? noteRepo.note(id: noteId) else { return }
        note = loaded
        title = loaded.title ?? ""
        body = loaded.body
    }

    func onEdited() {
        autosave.schedule()
    }

    func flushSave() {
        autosave.flush()
    }

    private func saveNow() {
        guard var n = note else { return }
        n.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title
        n.body = body
        try? noteRepo.save(n)
        note = n
    }
}

/// Inline editor for a single note (any kind), reached from `NotesLibraryView`.
/// For paper-linked notes, also offers opening the same note in the existing
/// detached per-paper notes window.
struct NoteEditorView: View {
    @StateObject private var model: NoteEditorViewModel
    @Environment(\.openWindow) private var openWindow
    private let paperId: String?

    init(noteId: String, database: DatabaseManager, paperId: String? = nil) {
        _model = StateObject(wrappedValue: NoteEditorViewModel(noteId: noteId, database: database))
        self.paperId = paperId
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Title", text: $model.title)
                    .textFieldStyle(.plain)
                    .font(.title3.bold())
                    .onChange(of: model.title) { _, _ in model.onEdited() }

                Spacer()

                if let paperId {
                    Button {
                        PendingReaderJump.set(paperId: paperId, pageIndex: 0)
                        openWindow(value: paperId)
                    } label: {
                        Label("Open PDF", systemImage: "doc.richtext")
                    }

                    Button {
                        openWindow(value: NotesWindowID(paperId: paperId))
                    } label: {
                        Label("Open in Window", systemImage: "macwindow")
                    }
                }
            }
            .padding(10)

            Divider()

            TextEditor(text: $model.body)
                .font(.body)
                .padding(8)
                .onChange(of: model.body) { _, _ in model.onEdited() }
        }
        .onAppear { model.load() }
        .onDisappear { model.flushSave() }
    }
}
