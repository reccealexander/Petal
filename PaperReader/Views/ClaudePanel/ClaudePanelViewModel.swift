import Foundation
import PaperReaderCore

/// Which entity the Claude panel is currently answering questions about
/// (Session 7 Part B, deliverable #1). A paper conversation and a notebook
/// conversation are persisted as separate `ChatSession` rows (`scope` +
/// `scope_id`), so switching between them never overwrites the other.
enum ClaudeChatScope {
    case paper(Paper)
    case notebook(Notebook)
}

/// Orchestrates the Claude side-panel chat for either a single paper or a
/// notebook. Owns the keychain/client/context-builder/repository backend
/// calls; the view only reads `@Published` state and calls these methods (no
/// business logic in the view, per spec).
@MainActor
final class ClaudePanelViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isStreaming: Bool = false
    @Published var streamingText: String = ""
    @Published var hasAPIKey: Bool = false
    @Published var includeContext: Bool = true
    @Published private(set) var currentSessionId: String?
    @Published private(set) var sessions: [ChatSession] = []

    private let scope: ClaudeChatScope
    private let papersDirectory: URL
    private let keychain: KeychainService
    private let gemini: GeminiClient
    private let claude: ClaudeClient
    private let contextBuilder: ContextBuilder
    private let chatRepo: ChatSessionRepository

    init(scope: ClaudeChatScope, database: DatabaseManager) {
        self.scope = scope
        self.papersDirectory = database.papersDirectory
        let keychain = KeychainService()
        self.keychain = keychain
        self.gemini = GeminiClient(keychain: keychain)
        self.claude = ClaudeClient(keychain: keychain)
        self.contextBuilder = ContextBuilder(database: database)
        self.chatRepo = ChatSessionRepository(database: database)
    }

    /// Convenience for existing paper-scope call sites.
    convenience init(paper: Paper, database: DatabaseManager) {
        self.init(scope: .paper(paper), database: database)
    }

    /// Convenience for notebook-scope call sites.
    convenience init(notebook: Notebook, database: DatabaseManager) {
        self.init(scope: .notebook(notebook), database: database)
    }

    private var chatScope: ChatSession.Scope {
        switch scope {
        case .paper: return .paper
        case .notebook: return .notebook
        }
    }

    private var scopeId: String {
        switch scope {
        case .paper(let paper): return paper.id
        case .notebook(let notebook): return notebook.id
        }
    }

    /// A human-readable title for the panel header: the paper's title or the
    /// notebook's name.
    var scopeTitle: String {
        switch scope {
        case .paper(let paper): return paper.title ?? "Untitled"
        case .notebook(let notebook): return notebook.name
        }
    }

    /// "Paper" or "Notebook" — used alongside `scopeTitle` in the header label.
    var scopeKind: String {
        switch scope {
        case .paper: return "Paper"
        case .notebook: return "Notebook"
        }
    }

    /// Whether the active scope is a notebook (vs. a paper) — used by the
    /// view to pick the paper-scope or notebook-scope quick-action set
    /// (Session 7 Part C).
    var isNotebookScope: Bool {
        if case .notebook = scope { return true }
        return false
    }

    /// Called when the panel appears: restores the most recent conversation
    /// for this scope, creating an empty one when this is the first chat.
    func onAppear() {
        hasAPIKey = AIProviderPreference.effectiveProvider(keychain: keychain) != nil
        refreshSessions()
        if let session = sessions.first {
            currentSessionId = session.id
            messages = chatRepo.messages(inSessionId: session.id)
        } else {
            createAndSelectEmptySession()
        }
    }

    /// Starts a separate conversation while preserving every prior session.
    func newChat() {
        guard !isStreaming else { return }
        createAndSelectEmptySession()
    }

    /// Reopens a conversation from this scope's history.
    func selectSession(_ id: String) {
        guard !isStreaming, sessions.contains(where: { $0.id == id }) else { return }
        currentSessionId = id
        messages = chatRepo.messages(inSessionId: id)
        streamingText = ""
    }

    /// Deletes one conversation. If it was open, falls back to the next most
    /// recent conversation or creates a new empty session when none remain.
    func deleteSession(_ id: String) {
        guard !isStreaming, sessions.contains(where: { $0.id == id }) else { return }
        try? chatRepo.deleteSession(id: id)
        let deletedCurrentSession = currentSessionId == id
        refreshSessions()

        guard deletedCurrentSession else { return }
        if let session = sessions.first {
            currentSessionId = session.id
            messages = chatRepo.messages(inSessionId: session.id)
            streamingText = ""
        } else {
            createAndSelectEmptySession()
        }
    }

    /// A compact history-menu label: first user prompt, or the creation date
    /// for an empty session.
    func displayTitle(for session: ChatSession) -> String {
        if let firstUserMessage = ChatSessionRepository.decode(session.messages)
            .first(where: { $0.role == "user" })?.content {
            let collapsed = firstUserMessage
                .split(whereSeparator: \Character.isWhitespace)
                .joined(separator: " ")
            if !collapsed.isEmpty {
                return collapsed.count > 40 ? String(collapsed.prefix(40)) + "…" : collapsed
            }
        }
        return "New chat · \(session.createdAt.formatted(date: .abbreviated, time: .shortened))"
    }

    /// Re-reads the API key state. Call when the panel reappears (e.g. after
    /// the user has been to Settings and back) so the empty state clears
    /// without requiring a relaunch.
    func refreshKeyState() {
        hasAPIKey = AIProviderPreference.effectiveProvider(keychain: keychain) != nil
    }

    /// Sends `inputText` to Claude, streaming the reply into `streamingText`
    /// and appending both turns to `messages` once complete.
    func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        inputText = ""
        await stream(userMessage: text, includeContext: includeContext)
    }

    /// Runs a quick action: inserts `message` (already composed by the view
    /// from `QuickActionPrompts` + the current reader/notebook context) as a
    /// USER message, then streams Claude's reply through the same path as a
    /// typed `send()` — the view is responsible for building the message and
    /// checking availability (Session 7 Part C); this method just knows how
    /// to run it, keeping the VM free of PDF/DB context assembly.
    func runQuickAction(_ message: String) async {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        await stream(userMessage: text, includeContext: true)
    }

    /// Appends `userMessage` to the conversation, persists it, then streams
    /// Claude's reply and persists again once it completes. Shared by `send()`
    /// (typed input) and `runQuickAction(_:)` (pre-composed quick-action
    /// prompts) so there's exactly one streaming/persist implementation.
    private func stream(userMessage: String, includeContext: Bool) async {
        guard let provider = AIProviderPreference.effectiveProvider(keychain: keychain) else {
            return
        }

        guard let sessionId = ensureCurrentSession() else { return }

        messages.append(ChatMessage(role: "user", content: userMessage))
        persistMessages(inSessionId: sessionId)

        // Rebuilt fresh on every send (rather than cached once per session) so
        // the system prompt always reflects the latest highlights/comments/
        // notes the user has made — staleness would be worse than the extra
        // extraction cost here. Built synchronously on the main actor BEFORE
        // the `await` below: `Paper`/`Notebook` cross the Core/App module
        // boundary and we want the whole prompt-construction step (including
        // any PDF reads) to finish before we hand off to the async stream, to
        // avoid "sending risks data races" under strict concurrency.
        let system: String
        if includeContext {
            switch scope {
            case .paper(let paper):
                let pdfURL = PDFImportService.fileURL(for: paper, in: papersDirectory)
                system = contextBuilder.buildPaperSystemPrompt(paper: paper, pdfURL: pdfURL)
            case .notebook(let notebook):
                system = contextBuilder.buildNotebookSystemPrompt(notebook: notebook)
            }
        } else {
            system = "You are a helpful assistant."
        }
        isStreaming = true
        streamingText = ""

        do {
            switch provider {
            case .claude:
                let claudeMessages = messages.map { ClaudeMessage(role: $0.role, content: $0.content) }
                for try await delta in claude.streamMessage(system: system, messages: claudeMessages) {
                    streamingText += delta
                }
            case .gemini:
                let geminiMessages = messages.map { GeminiMessage(role: $0.role, content: $0.content) }
                for try await delta in gemini.streamMessage(system: system, messages: geminiMessages) {
                    streamingText += delta
                }
            }
            messages.append(ChatMessage(role: "assistant", content: streamingText))
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            messages.append(ChatMessage(role: "assistant", content: description))
        }

        streamingText = ""
        isStreaming = false
        persistMessages(inSessionId: sessionId)
    }

    private func refreshSessions() {
        sessions = chatRepo.sessions(scope: chatScope, scopeId: scopeId)
    }

    private func createAndSelectEmptySession() {
        guard let session = try? chatRepo.createSession(scope: chatScope, scopeId: scopeId) else { return }
        currentSessionId = session.id
        messages = []
        streamingText = ""
        refreshSessions()
    }

    private func ensureCurrentSession() -> String? {
        if let currentSessionId { return currentSessionId }
        createAndSelectEmptySession()
        return currentSessionId
    }

    private func persistMessages(inSessionId id: String) {
        try? chatRepo.saveMessages(messages, inSessionId: id)
        refreshSessions()
    }
}
