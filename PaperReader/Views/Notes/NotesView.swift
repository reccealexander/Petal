import SwiftUI
import PaperReaderCore

/// The detached notes window for a paper: a split raw/preview markdown editor
/// with debounced autosave and clickable highlight references (spec §4).
struct NotesView: View {
    @StateObject private var model: NotesViewModel
    @Environment(\.openWindow) private var openWindow

    init(paperId: String, paperTitle: String, database: DatabaseManager) {
        _model = StateObject(wrappedValue: NotesViewModel(paperId: paperId, paperTitle: paperTitle, database: database))
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
            }
            .padding(8)

            VSplitView {
                TextEditor(text: $model.body)
                    .font(.body.monospaced())
                    .padding(8)
                    .frame(minHeight: 160)
                    .onChange(of: model.body) { _, _ in
                        model.onBodyEdited()
                    }

                ScrollView {
                    Text(renderedMarkdown)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .frame(minHeight: 140)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let parsed = HighlightLink.parse(url) {
                openWindow(value: model.paperId)
                NotificationCenter.default.post(
                    name: .readerJumpToHighlight, object: nil,
                    userInfo: ["paperId": model.paperId, "pageIndex": parsed.pageIndex])
                return .handled
            }
            return .systemAction
        })
        .navigationTitle(model.paperTitle)
        .onAppear { model.load() }
        .onDisappear { model.flushSave() }
        .frame(minWidth: 380, minHeight: 420)
    }

    /// Renders `model.body` as inline markdown (links, emphasis, etc.), falling
    /// back to the raw text if parsing fails.
    private var renderedMarkdown: AttributedString {
        (try? AttributedString(
            markdown: model.body,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                           failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(model.body)
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
