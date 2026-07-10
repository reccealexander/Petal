import SwiftUI
import PaperReaderCore

/// A Claude Q&A side panel that can operate in either paper scope or
/// notebook scope (spec §5, Session 7 Part B extends this to notebooks).
///
/// Implemented as a conditional pane inside the host view's existing
/// `HStack` (mirroring the Part A thumbnail sidebar) rather than a literal
/// third `NSSplitViewController` pane — this meets the "slides in, toolbar
/// toggled" deliverable with far less plumbing than a real split view
/// controller, at the cost of not being independently resizable by dragging.
///
/// When opened for a paper that belongs to a notebook, a "Paper | Notebook"
/// segmented switcher lets the user swap the active scope without losing
/// either conversation: each scope persists under its own `ChatSession` row
/// (`scope` + `scope_id`), so switching just swaps which `ClaudePanelViewModel`
/// is active and reloads that scope's already-persisted messages.
struct ClaudePanelView: View {
    private enum Mode {
        case paper
        case notebook
    }

    @State private var viewModel: ClaudePanelViewModel
    @State private var mode: Mode

    private let database: DatabaseManager
    private let paper: Paper?
    private let containingNotebook: Notebook?

    /// Paper-scope entry point (used by `PDFReaderView`). Looks up the
    /// paper's containing notebook (if any) so the header can offer the
    /// paper/notebook switcher; unfiled papers (`notebookId == nil`) just show
    /// the paper indicator with no switcher.
    init(paper: Paper, database: DatabaseManager) {
        self.database = database
        self.paper = paper
        let notebook: Notebook? = paper.notebookId.flatMap { notebookId in
            try? NotebookRepository(database: database).notebook(id: notebookId)
        }
        self.containingNotebook = notebook
        _mode = State(initialValue: .paper)
        _viewModel = State(initialValue: ClaudePanelViewModel(paper: paper, database: database))
    }

    /// Notebook-scope entry point (used by the Home window). No current
    /// paper, so no switcher is shown — just the notebook indicator.
    init(notebook: Notebook, database: DatabaseManager) {
        self.database = database
        self.paper = nil
        self.containingNotebook = notebook
        _mode = State(initialValue: .notebook)
        _viewModel = State(initialValue: ClaudePanelViewModel(notebook: notebook, database: database))
    }

    /// Generic entry point taking an explicit `ClaudeChatScope`. Notebook
    /// scope never shows a switcher (no paper is known); paper scope behaves
    /// like `init(paper:database:)`.
    init(scope: ClaudeChatScope, database: DatabaseManager) {
        switch scope {
        case .paper(let paper):
            self.init(paper: paper, database: database)
        case .notebook(let notebook):
            self.init(notebook: notebook, database: database)
        }
    }

    /// Only a paper opened from within a notebook offers the switcher —
    /// there's nothing to switch to/from otherwise.
    private var showsSwitcher: Bool {
        paper != nil && containingNotebook != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if showsSwitcher {
                switcher
            }
            Divider()
            ClaudePanelContentView(viewModel: viewModel)
        }
        .frame(width: 340)
        .onAppear {
            viewModel.onAppear()
            viewModel.refreshKeyState()
        }
    }

    // MARK: - Header / switcher

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
            Text("Asking about \(viewModel.scopeKind.lowercased()): \(viewModel.scopeTitle)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, showsSwitcher ? 4 : 8)
    }

    private var switcher: some View {
        Picker("Scope", selection: $mode) {
            Text("Paper").tag(Mode.paper)
            Text("Notebook").tag(Mode.notebook)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .onChange(of: mode) { _, newMode in switchMode(to: newMode) }
    }

    /// Swaps the active view-model to the requested scope and restores that
    /// scope's persisted conversation. Because each scope is backed by its
    /// own `ChatSession` row, the conversation we're switching away from is
    /// untouched and will still be there if the user switches back.
    private func switchMode(to newMode: Mode) {
        switch newMode {
        case .paper:
            guard let paper else { return }
            viewModel = ClaudePanelViewModel(paper: paper, database: database)
        case .notebook:
            guard let containingNotebook else { return }
            viewModel = ClaudePanelViewModel(notebook: containingNotebook, database: database)
        }
        viewModel.onAppear()
        viewModel.refreshKeyState()
    }
}

/// The actual chat UI (no-API-key state + message list + input bar),
/// factored out so it can subscribe to whichever `ClaudePanelViewModel` is
/// currently active via `@ObservedObject` — `ClaudePanelView` itself holds
/// the view-model in `@State` so it can be swapped wholesale on a scope
/// switch (see `ClaudePanelView.switchMode`).
private struct ClaudePanelContentView: View {
    @ObservedObject var viewModel: ClaudePanelViewModel

    var body: some View {
        Group {
            if viewModel.hasAPIKey {
                chatBody
            } else {
                noKeyBody
            }
        }
    }

    // MARK: - No API key state

    private var noKeyBody: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "key.slash")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No Anthropic API key set")
                .font(.headline)
            Text("Add your Anthropic API key in Settings to ask Claude about this \(viewModel.scopeKind.lowercased()).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            SettingsLink {
                Text("Open Settings…")
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Chat state

    private var chatBody: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.messages) { message in
                            ChatBubble(message: message)
                                .id(message.id)
                        }
                        if viewModel.isStreaming {
                            ChatBubble(
                                message: ChatMessage(role: "assistant", content: viewModel.streamingText),
                                isStreaming: true
                            )
                            .id("streaming")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: viewModel.streamingText) { _, _ in
                    scrollToBottom(proxy)
                }
            }

            Divider()
            inputBar
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about this \(viewModel.scopeKind.lowercased())…", text: $viewModel.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                .onSubmit(sendMessage)

            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isStreaming || viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
    }

    private func sendMessage() {
        guard !viewModel.isStreaming else { return }
        Task { await viewModel.send() }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation {
            if viewModel.isStreaming {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if let last = viewModel.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

/// A single chat message bubble: right-aligned/accent for the user,
/// left-aligned/secondary for the assistant.
private struct ChatBubble: View {
    let message: ChatMessage
    var isStreaming: Bool = false

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 24) }

            VStack(alignment: .leading, spacing: 4) {
                Text(message.content.isEmpty ? " " : message.content)
                    .textSelection(.enabled)
                if isStreaming {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isUser ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
            )

            if !isUser { Spacer(minLength: 24) }
        }
    }
}
