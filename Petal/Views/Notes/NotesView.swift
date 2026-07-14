import SwiftUI
import PetalCore

/// The detached notes window for a paper: an RTF-backed rich-text editor
/// with debounced autosave and clickable highlight references (spec §4).
struct NotesView: View {
    @StateObject private var model: NotesViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var isConfirmingDelete = false
    private let onClosePane: (() -> Void)?

    init(
        paperId: String,
        paperTitle: String,
        database: DatabaseManager,
        onClosePane: (() -> Void)? = nil
    ) {
        _model = StateObject(wrappedValue: NotesViewModel(paperId: paperId, paperTitle: paperTitle, database: database))
        self.onClosePane = onClosePane
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    if model.highlights.isEmpty {
                        Text("No highlights yet")
                            .disabled(true)
                    } else {
                        ForEach(model.highlights) { highlight in
                            Button("p.\(highlight.page + 1): \(shortSnippet(highlight))") {
                                model.insertReference(to: highlight)
                            }
                        }
                    }
                } label: {
                    Label("Insert Reference", systemImage: "quote.opening")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                if let onClosePane {
                    Button {
                        // Flush synchronously before requesting joined-window
                        // teardown so a pending debounced edit is preserved.
                        model.flushSave()
                        onClosePane()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Close Note Pane")
                    .accessibilityLabel("Close Note Pane")
                }
            }
            .padding(8)

            RichTextEditorView(
                text: $model.attributedText,
                onEdit: model.onBodyEdited,
                onOpenHighlight: openHighlight)
        }
        .navigationTitle(model.paperTitle)
        .onAppear { model.load() }
        .onDisappear { model.flushSave() }
        .frame(minWidth: 380, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    PendingReaderJump.set(paperId: model.paperId, pageIndex: 0)
                    openWindow(value: model.paperId)
                } label: {
                    Label("Open PDF", systemImage: "doc.richtext")
                }
                .help("Open PDF")
            }
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Delete Note", systemImage: "trash")
                }
                .help("Delete Note")
            }
        }
        .alert("Delete this note?", isPresented: $isConfirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                model.deleteNote()
                NotesPaneCloseRequest.post(paperId: model.paperId)
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    private func openHighlight(_ url: URL) {
        guard let parsed = HighlightLink.parse(url) else { return }
        PendingReaderJump.set(paperId: model.paperId, pageIndex: parsed.pageIndex)
        openWindow(value: model.paperId)
        NotificationCenter.default.post(
            name: .readerJumpToHighlight, object: nil,
            userInfo: ["paperId": model.paperId, "pageIndex": parsed.pageIndex])
    }

    /// A single-line, ~40-character preview of a highlight's selected text,
    /// used as the menu item title.
    private func shortSnippet(_ h: Highlight) -> String {
        let collapsed = h.selectedText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > 40 else { return collapsed }
        return String(collapsed.prefix(40)) + "…"
    }
}
