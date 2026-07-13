import SwiftUI
import AppKit
import PaperReaderCore
import SwiftMath

/// The live PDF-reader context the Claude panel's quick actions draw on
/// (Session 7 Part C). Built by `PDFReaderView` from `PDFReaderModel`'s
/// provider closures and threaded into `ClaudePanelView` as an optional
/// parameter — `nil` wherever there's no live reader (e.g. the Home window's
/// notebook-scope panel), so those call sites just show the two quick
/// actions that don't need reader context.
struct ReaderQuickActionSource {
    var selection: () -> String?
    var surrounding: () -> String?
    var pageText: () -> String?
    var openHighlight: () -> (text: String, comment: String?)?
}

/// A Claude Q&A side panel that can operate in either paper scope or
/// notebook scope (spec §5, Session 7 Part B extends this to notebooks).
///
/// Implemented as a conditional pane inside the host view's existing
/// `HStack` (mirroring the Part A thumbnail sidebar) rather than a literal
/// third `NSSplitViewController` pane — this meets the "slides in, toolbar
/// toggled" deliverable with far less plumbing than a real split view
/// controller. The host HStack supplies a draggable separator and persists
/// this pane's width through `AppearanceManager`.
///
/// When opened for a paper that belongs to a notebook, a "Paper | Notebook"
/// segmented switcher lets the user swap the active scope without losing
/// either conversation history: each scope has its own set of `ChatSession`
/// rows (`scope` + `scope_id`), so switching swaps the active
/// `ClaudePanelViewModel` and reloads that scope's most recent session.
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
    /// Live PDF-selection/highlight context for the reader's quick actions;
    /// `nil` when there's no reader (e.g. opened from the Home window).
    private let readerSource: ReaderQuickActionSource?
    private let onScopeChange: ((Bool) -> Void)?

    /// Paper-scope entry point (used by `PDFReaderView`). Looks up the
    /// paper's containing notebook (if any) so the header can offer the
    /// paper/notebook switcher; unfiled papers (`notebookId == nil`) just show
    /// the paper indicator with no switcher. `readerSource` (optional) wires
    /// the paper/notebook quick actions to the live PDF selection/highlight.
    init(
        paper: Paper,
        database: DatabaseManager,
        readerSource: ReaderQuickActionSource? = nil,
        initialNotebookScope: Bool = false,
        onScopeChange: ((Bool) -> Void)? = nil
    ) {
        self.database = database
        self.paper = paper
        let notebook: Notebook? = paper.notebookId.flatMap { notebookId in
            try? NotebookRepository(database: database).notebook(id: notebookId)
        }
        self.containingNotebook = notebook
        self.readerSource = readerSource
        self.onScopeChange = onScopeChange
        let startsInNotebook = initialNotebookScope && notebook != nil
        _mode = State(initialValue: startsInNotebook ? .notebook : .paper)
        _viewModel = State(initialValue: startsInNotebook
            ? ClaudePanelViewModel(notebook: notebook!, database: database)
            : ClaudePanelViewModel(paper: paper, database: database))
    }

    /// Notebook-scope entry point (used by the Home window). No current
    /// paper, so no switcher is shown — just the notebook indicator. No live
    /// reader either, so quick actions that need PDF context are unavailable
    /// (the notebook-only actions still work).
    init(notebook: Notebook, database: DatabaseManager) {
        self.database = database
        self.paper = nil
        self.containingNotebook = notebook
        self.readerSource = nil
        self.onScopeChange = nil
        _mode = State(initialValue: .notebook)
        _viewModel = State(initialValue: ClaudePanelViewModel(notebook: notebook, database: database))
    }

    /// Generic entry point taking an explicit `ClaudeChatScope`. Notebook
    /// scope never shows a switcher (no paper is known); paper scope behaves
    /// like `init(paper:database:readerSource:)`.
    init(scope: ClaudeChatScope, database: DatabaseManager, readerSource: ReaderQuickActionSource? = nil) {
        switch scope {
        case .paper(let paper):
            self.init(paper: paper, database: database, readerSource: readerSource)
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
            ClaudePanelContentView(
                viewModel: viewModel,
                readerSource: readerSource,
                paperTitle: paper?.title,
                notebookName: containingNotebook?.name
            )
        }
        .onAppear {
            viewModel.onAppear()
            viewModel.refreshKeyState()
            onScopeChange?(viewModel.isNotebookScope)
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
            ChatSessionControls(viewModel: viewModel)
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
    /// scope's persisted conversation history. The sessions belonging to the
    /// scope we're switching away from remain untouched.
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
        onScopeChange?(viewModel.isNotebookScope)
    }
}

/// Compact, provider-agnostic session controls shared by every panel host.
/// Keeping these in `ClaudePanelView`'s header makes them available in the
/// docked reader, Home notebook panel, and standalone Focus chat window.
private struct ChatSessionControls: View {
    @ObservedObject var viewModel: ClaudePanelViewModel
    @State private var sessionIdPendingDelete: String?

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                if viewModel.sessions.isEmpty {
                    Text("No chats yet")
                        .disabled(true)
                } else {
                    Section("Chat History") {
                        ForEach(viewModel.sessions) { session in
                            Button {
                                viewModel.selectSession(session.id)
                            } label: {
                                if session.id == viewModel.currentSessionId {
                                    Label(viewModel.displayTitle(for: session), systemImage: "checkmark")
                                } else {
                                    Text(viewModel.displayTitle(for: session))
                                }
                            }
                        }
                    }

                    Divider()

                    Menu("Delete Chat…", systemImage: "trash") {
                        ForEach(viewModel.sessions) { session in
                            Button(viewModel.displayTitle(for: session), role: .destructive) {
                                sessionIdPendingDelete = session.id
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(viewModel.isStreaming)
            .help("Chat History")

            Button {
                viewModel.newChat()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isStreaming)
            .help("New Chat")
        }
        .alert(
            "Delete this chat?",
            isPresented: Binding(
                get: { sessionIdPendingDelete != nil },
                set: { if !$0 { sessionIdPendingDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                sessionIdPendingDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let id = sessionIdPendingDelete {
                    viewModel.deleteSession(id)
                }
                sessionIdPendingDelete = nil
            }
        } message: {
            Text("This permanently removes only this chat and its messages.")
        }
    }
}

/// The actual chat UI (no-API-key state + message list + input bar),
/// factored out so it can subscribe to whichever `ClaudePanelViewModel` is
/// currently active via `@ObservedObject` — `ClaudePanelView` itself holds
/// the view-model in `@State` so it can be swapped wholesale on a scope
/// switch (see `ClaudePanelView.switchMode`).
private struct ClaudePanelContentView: View {
    @ObservedObject var viewModel: ClaudePanelViewModel
    let readerSource: ReaderQuickActionSource?
    let paperTitle: String?
    let notebookName: String?

    var body: some View {
        Group {
            if viewModel.hasAPIKey {
                chatBody
            } else {
                noKeyBody
            }
        }
    }

    // MARK: - Quick actions (Session 7 Part C)

    /// The paper-scope actions when the active scope is a paper, the
    /// notebook-scope actions when it's a notebook.
    private var quickActions: [QuickAction] {
        viewModel.isNotebookScope ? QuickAction.notebookActions : QuickAction.paperActions
    }

    /// Assembled fresh on every access from the live reader-source closures
    /// (if any) plus the scope's paper/notebook titles — cheap enough (a
    /// couple of PDFKit string reads) to not bother caching, and it keeps
    /// the quick-action buttons always reflecting the current selection.
    private var quickActionContext: QuickActionContext {
        let openHighlight = readerSource?.openHighlight()
        return QuickActionContext(
            selection: readerSource?.selection(),
            surrounding: readerSource?.surrounding(),
            pageText: readerSource?.pageText(),
            highlightText: openHighlight?.text,
            commentText: openHighlight?.comment,
            paperTitle: paperTitle,
            notebookName: notebookName
        )
    }

    private var quickActionsBar: some View {
        let context = quickActionContext
        return FlowLayout(spacing: 6) {
            ForEach(quickActions) { action in
                quickActionButton(action, context: context)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private func quickActionButton(_ action: QuickAction, context: QuickActionContext) -> some View {
        let message = QuickActionPrompts.userMessage(for: action, context: context)
        let reason = QuickActionPrompts.unavailableReason(for: action, context: context)
        let isDisabled = message == nil || viewModel.isStreaming

        return Button {
            guard let message else { return }
            Task { await viewModel.runQuickAction(message) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: action.systemImage)
                    .font(.caption2)
                Text(action.title)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
        .help(reason ?? (viewModel.isStreaming ? "AI is currently responding." : action.title))
    }

    // MARK: - No API key state

    private var noKeyBody: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "key.slash")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No AI API key set")
                .font(.headline)
            Text("Add a Claude or Gemini API key in Settings to ask about this \(viewModel.scopeKind.lowercased()).")
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
            quickActionsBar
            contextToggle
            inputBar
        }
    }

    private var contextToggle: some View {
        Toggle("Include \(viewModel.scopeKind.lowercased()) context", isOn: $viewModel.includeContext)
            .toggleStyle(.switch)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.top, 8)
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
    @EnvironmentObject private var appearance: AppearanceManager

    private var isUser: Bool { message.role == "user" }

    private enum MarkdownSegment: Identifiable {
        case text(Int, String)
        case code(Int, String)

        var id: Int {
            switch self {
            case .text(let id, _), .code(let id, _): return id
            }
        }
    }

    private enum ProseBlock: Identifiable {
        case proseLine(Int, Int?, String)
        case displayMath(Int, String, String)
        case blank(Int)

        var id: Int {
            switch self {
            case .proseLine(let id, _, _), .displayMath(let id, _, _), .blank(let id): id
            }
        }
    }

    private enum InlineRun: Identifiable {
        case text(Int, String)
        case math(Int, latex: String, source: String)

        var id: Int {
            switch self {
            case .text(let id, _), .math(let id, _, _): id
            }
        }
    }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 24) }

            VStack(alignment: .leading, spacing: 4) {
                if isUser {
                    Text(message.content.isEmpty ? " " : message.content)
                        .font(chatFont)
                        .textSelection(.enabled)
                } else {
                    assistantContent
                }
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

    @ViewBuilder
    private var assistantContent: some View {
        let segments = markdownSegments(message.content.isEmpty ? " " : message.content)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(segments) { segment in
                switch segment {
                case .text(_, let content):
                    proseContent(content)
                case .code(_, let content):
                    Text(content)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.06))
                        )
                }
            }
        }
    }

    @ViewBuilder
    private func proseContent(_ content: String) -> some View {
        let blocks = proseBlocks(in: content)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(blocks, id: \.id) { (block: ProseBlock) in
                switch block {
                case let .proseLine(_, level, content):
                    inlineContent(
                        readableListMarkers(in: content),
                        font: level.map(headerFont) ?? chatFont,
                        fontSize: level.map(headerFontSize) ?? chatFontSize
                    )
                case let .displayMath(_, latex, _):
                    MathLabel(latex: latex, fontSize: chatFontSize, mode: .display)
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .center)
                case .blank:
                    Color.clear.frame(height: max(2, chatFontSize * 0.35))
                }
            }
        }
    }

    /// SwiftUI `Text` cannot embed an `NSView`, so mixed prose/math is split
    /// into ordered runs and placed by a small wrapping `Layout`. A long prose
    /// run may wrap before the following formula instead of breaking at every
    /// word, but short inline formulas stay in the surrounding line and all
    /// markdown attributes within each prose run remain intact.
    @ViewBuilder
    private func inlineContent(_ content: String, font: Font, fontSize: CGFloat) -> some View {
        let runs = inlineRuns(in: content)
        InlineMathFlowLayout(spacing: 2) {
            ForEach(runs, id: \.id) { (run: InlineRun) in
                switch run {
                case let .text(_, text):
                    Text(inlineMarkdown(from: text))
                        .font(font)
                        .textSelection(.enabled)
                case let .math(_, latex, _):
                    MathLabel(latex: latex, fontSize: fontSize, mode: .text)
                        .fixedSize()
                }
            }
        }
    }

    private var chatFont: Font {
        appearance.chatFontName == "System"
            ? .system(size: chatFontSize)
            : .custom(appearance.chatFontName, size: chatFontSize)
    }

    private var chatFontSize: CGFloat { CGFloat(appearance.chatFontSize) }

    private func headerFont(_ level: Int) -> Font {
        let size = headerFontSize(level)
        return appearance.chatFontName == "System"
            ? .system(size: size, weight: .bold)
            : .custom(appearance.chatFontName, size: size).bold()
    }

    private func headerFontSize(_ level: Int) -> CGFloat {
        let scale: CGFloat = switch level {
        case 1: 1.55
        case 2: 1.35
        default: 1.18
        }
        return chatFontSize * scale
    }

    private func inlineMarkdown(from content: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: content, options: options)) ?? AttributedString(content)
    }

    /// Makes simple unordered lists typographically readable while leaving
    /// numbered markers and all line breaks intact for inline parsing.
    private func readableListMarkers(in content: String) -> String {
        content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    return "•  " + line.dropFirst(2)
                }
                return String(line)
            }
            .joined(separator: "\n")
    }

    /// Separates display math first, then turns prose into independently
    /// styled lines so Markdown ATX headers can use fonts derived from the
    /// user's chat font. Unclosed delimiters remain prose while streaming.
    private func proseBlocks(in content: String) -> [ProseBlock] {
        enum RawBlock {
            case prose(String)
            case math(latex: String, source: String)
        }

        var rawBlocks: [RawBlock] = []
        var cursor = content.startIndex
        var searchStart = cursor

        while let opening = nextDisplayOpening(in: content, from: searchStart) {
            let closingDelimiter = opening.delimiter == "$$" ? "$$" : "\\]"
            let mathStart = opening.range.upperBound
            guard let closing = nextClosing(
                closingDelimiter,
                in: content,
                from: mathStart,
                singleDollar: false
            ) else {
                break
            }

            let latex = String(content[mathStart..<closing.lowerBound])
            guard !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  isValidMath(latex) else {
                searchStart = closing.upperBound
                continue
            }

            if cursor < opening.range.lowerBound {
                rawBlocks.append(.prose(String(content[cursor..<opening.range.lowerBound])))
            }
            rawBlocks.append(.math(
                latex: latex,
                source: String(content[opening.range.lowerBound..<closing.upperBound])
            ))
            cursor = closing.upperBound
            searchStart = cursor
        }

        if cursor < content.endIndex || rawBlocks.isEmpty {
            rawBlocks.append(.prose(String(content[cursor...])))
        }

        var blocks: [ProseBlock] = []
        for rawBlock in rawBlocks {
            switch rawBlock {
            case .math(let latex, let source):
                blocks.append(.displayMath(blocks.count, latex, source))
            case .prose(let prose):
                for line in prose.split(separator: "\n", omittingEmptySubsequences: false) {
                    let text = String(line)
                    if text.isEmpty {
                        blocks.append(.blank(blocks.count))
                    } else {
                        let header = parsedHeader(text)
                        blocks.append(.proseLine(blocks.count, header?.level, header?.content ?? text))
                    }
                }
            }
        }
        return blocks
    }

    private func parsedHeader(_ line: String) -> (level: Int, content: String)? {
        var index = line.startIndex
        var level = 0
        while index < line.endIndex, line[index] == "#", level < 4 {
            level += 1
            index = line.index(after: index)
        }
        guard (1...3).contains(level), index == line.endIndex || line[index] != "#" else { return nil }
        if index < line.endIndex, line[index] == " " {
            index = line.index(after: index)
        }
        return (level, String(line[index...]))
    }

    private func inlineRuns(in content: String) -> [InlineRun] {
        var runs: [InlineRun] = []
        var cursor = content.startIndex
        var searchStart = cursor

        while let opening = nextInlineOpening(in: content, from: searchStart) {
            let closingDelimiter = opening.delimiter == "$" ? "$" : "\\)"
            let mathStart = opening.range.upperBound
            guard let closing = nextClosing(
                closingDelimiter,
                in: content,
                from: mathStart,
                singleDollar: opening.delimiter == "$"
            ) else { break }

            let latex = String(content[mathStart..<closing.lowerBound])
            guard isPlausibleInlineMath(latex), isValidMath(latex) else {
                searchStart = closing.upperBound
                continue
            }

            if cursor < opening.range.lowerBound {
                runs.append(.text(runs.count, String(content[cursor..<opening.range.lowerBound])))
            }
            runs.append(.math(
                runs.count,
                latex: latex,
                source: String(content[opening.range.lowerBound..<closing.upperBound])
            ))
            cursor = closing.upperBound
            searchStart = cursor
        }

        if cursor < content.endIndex || runs.isEmpty {
            runs.append(.text(runs.count, String(content[cursor...])))
        }
        return runs
    }

    private func nextDisplayOpening(
        in content: String,
        from start: String.Index
    ) -> (range: Range<String.Index>, delimiter: String)? {
        nextOpening(delimiters: ["$$", "\\["], in: content, from: start)
    }

    private func nextInlineOpening(
        in content: String,
        from start: String.Index
    ) -> (range: Range<String.Index>, delimiter: String)? {
        var position = start
        while let opening = nextOpening(delimiters: ["$", "\\("], in: content, from: position) {
            if opening.delimiter == "$" {
                let after = opening.range.upperBound
                if (after < content.endIndex && content[after] == "$") || isEscaped(opening.range.lowerBound, in: content) {
                    position = after
                    continue
                }
            }
            return opening
        }
        return nil
    }

    private func nextOpening(
        delimiters: [String],
        in content: String,
        from start: String.Index
    ) -> (range: Range<String.Index>, delimiter: String)? {
        delimiters.compactMap { delimiter -> (Range<String.Index>, String)? in
            guard let range = firstUnescapedRange(of: delimiter, in: content, from: start) else { return nil }
            return (range, delimiter)
        }
        .min { $0.0.lowerBound < $1.0.lowerBound }
        .map { ($0.0, $0.1) }
    }

    private func firstUnescapedRange(
        of delimiter: String,
        in content: String,
        from start: String.Index
    ) -> Range<String.Index>? {
        var position = start
        while let range = content.range(of: delimiter, range: position..<content.endIndex) {
            if !isEscaped(range.lowerBound, in: content) {
                return range
            }
            position = range.upperBound
        }
        return nil
    }

    private func nextClosing(
        _ delimiter: String,
        in content: String,
        from start: String.Index,
        singleDollar: Bool
    ) -> Range<String.Index>? {
        var position = start
        while let range = content.range(of: delimiter, range: position..<content.endIndex) {
            let after = range.upperBound
            if !isEscaped(range.lowerBound, in: content),
               !(singleDollar && after < content.endIndex && content[after] == "$") {
                return range
            }
            position = after
        }
        return nil
    }

    private func isEscaped(_ index: String.Index, in content: String) -> Bool {
        var slashCount = 0
        var cursor = index
        while cursor > content.startIndex {
            let previous = content.index(before: cursor)
            guard content[previous] == "\\" else { break }
            slashCount += 1
            cursor = previous
        }
        return slashCount.isMultiple(of: 2) == false
    }

    private func isPlausibleInlineMath(_ latex: String) -> Bool {
        guard !latex.isEmpty, !latex.contains("\n"),
              latex.first?.isWhitespace == false,
              latex.last?.isWhitespace == false else { return false }
        // Avoid treating common currency prose such as "$5 and $10" as math.
        if latex.first?.isNumber == true && latex.contains(where: \Character.isWhitespace) {
            return false
        }
        return true
    }

    private func isValidMath(_ latex: String) -> Bool {
        var error: NSError?
        let list = MTMathListBuilder.build(fromString: latex, error: &error)
        return list != nil && error == nil
    }

    /// Splits triple-backtick fences from prose. An optional language label
    /// on the opening fence is omitted from the displayed code block.
    private func markdownSegments(_ content: String) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        var proseLines: [Substring] = []
        var codeLines: [Substring] = []
        var isInCodeFence = false

        func appendProse() {
            guard !proseLines.isEmpty else { return }
            segments.append(.text(segments.count, proseLines.joined(separator: "\n")))
            proseLines.removeAll()
        }

        func appendCode() {
            segments.append(.code(segments.count, codeLines.joined(separator: "\n")))
            codeLines.removeAll()
        }

        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if isInCodeFence {
                    appendCode()
                } else {
                    appendProse()
                }
                isInCodeFence.toggle()
            } else if isInCodeFence {
                codeLines.append(line)
            } else {
                proseLines.append(line)
            }
        }

        if isInCodeFence {
            // Preserve an unmatched opening fence rather than losing content.
            proseLines.append("```")
            proseLines.append(contentsOf: codeLines)
        }
        appendProse()
        return segments
    }
}

/// AppKit-backed SwiftMath label sized to its intrinsic formula dimensions.
private struct MathLabel: NSViewRepresentable {
    let latex: String
    let fontSize: CGFloat
    let mode: MTMathUILabelMode

    func makeNSView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        label.displayErrorInline = false
        configure(label)
        return label
    }

    func updateNSView(_ label: MTMathUILabel, context: Context) {
        configure(label)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: MTMathUILabel,
        context: Context
    ) -> CGSize? {
        nsView.fittingSize
    }

    private func configure(_ label: MTMathUILabel) {
        label.labelMode = mode
        label.fontSize = fontSize
        label.textColor = .labelColor
        label.textAlignment = mode == .display ? .center : .left
        label.latex = latex
    }
}

/// A compact flow layout for alternating prose and intrinsic-size math views.
private struct InlineMathFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
            subviews: subviews
        )
        for (index, point) in result.points.enumerated() {
            let size = result.sizes[index]
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
        }
    }

    private func layout(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> (size: CGSize, points: [CGPoint], sizes: [CGSize]) {
        let availableWidth = proposal.width ?? .infinity
        var points: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0

        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > availableWidth {
                size = subview.sizeThatFits(ProposedViewSize(width: availableWidth, height: nil))
            }
            if x > 0, x + size.width > availableWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            sizes.append(size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            measuredWidth = max(measuredWidth, x - spacing)
        }

        return (CGSize(width: min(measuredWidth, availableWidth), height: y + rowHeight), points, sizes)
    }
}
