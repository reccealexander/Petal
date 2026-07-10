import Foundation
import PaperReaderCore

/// Orchestrates the Claude side-panel chat for a single paper. Owns the
/// keychain/client/context-builder/repository backend calls; the view only
/// reads `@Published` state and calls these methods (no business logic in
/// the view, per spec).
@MainActor
final class ClaudePanelViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isStreaming: Bool = false
    @Published var streamingText: String = ""
    @Published var hasAPIKey: Bool = false

    private let paper: Paper
    private let pdfURL: URL
    private let keychain: KeychainService
    private let claude: ClaudeClient
    private let contextBuilder: ContextBuilder
    private let chatRepo: ChatSessionRepository

    init(paper: Paper, database: DatabaseManager) {
        self.paper = paper
        self.pdfURL = PDFImportService.fileURL(for: paper, in: database.papersDirectory)
        let keychain = KeychainService()
        self.keychain = keychain
        self.claude = ClaudeClient(keychain: keychain)
        self.contextBuilder = ContextBuilder(database: database)
        self.chatRepo = ChatSessionRepository(database: database)
    }

    /// Called when the panel appears: restores the persisted conversation and
    /// refreshes the API-key state.
    func onAppear() {
        hasAPIKey = keychain.hasAPIKey
        messages = chatRepo.loadMessages(scope: .paper, scopeId: paper.id)
    }

    /// Re-reads the API key state. Call when the panel reappears (e.g. after
    /// the user has been to Settings and back) so the empty state clears
    /// without requiring a relaunch.
    func refreshKeyState() {
        hasAPIKey = keychain.hasAPIKey
    }

    /// Sends `inputText` to Claude, streaming the reply into `streamingText`
    /// and appending both turns to `messages` once complete.
    func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        messages.append(ChatMessage(role: "user", content: text))
        inputText = ""
        try? chatRepo.saveMessages(messages, scope: .paper, scopeId: paper.id)

        // Rebuilt fresh on every send (rather than cached once per session) so
        // the system prompt always reflects the latest highlights/comments the
        // user has made while reading — staleness would be worse than the
        // extra PDF-text-extraction cost here.
        let system = contextBuilder.buildPaperSystemPrompt(paper: paper, pdfURL: pdfURL)
        let claudeMessages = messages.map { ClaudeMessage(role: $0.role, content: $0.content) }

        isStreaming = true
        streamingText = ""

        do {
            for try await delta in claude.streamMessage(system: system, messages: claudeMessages) {
                streamingText += delta
            }
            messages.append(ChatMessage(role: "assistant", content: streamingText))
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            messages.append(ChatMessage(role: "assistant", content: description))
        }

        streamingText = ""
        isStreaming = false
        try? chatRepo.saveMessages(messages, scope: .paper, scopeId: paper.id)
    }
}
