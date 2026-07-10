import SwiftUI
import PaperReaderCore

/// A paper-scoped Claude Q&A side panel (spec §5).
///
/// Implemented as a conditional pane inside `PDFReaderView`'s existing
/// `HStack` (mirroring the Part A thumbnail sidebar) rather than a literal
/// third `NSSplitViewController` pane — this meets the "slides in, toolbar
/// toggled" deliverable with far less plumbing than a real split view
/// controller, at the cost of not being independently resizable by dragging.
struct ClaudePanelView: View {
    @StateObject private var viewModel: ClaudePanelViewModel

    init(paper: Paper, database: DatabaseManager) {
        _viewModel = StateObject(wrappedValue: ClaudePanelViewModel(paper: paper, database: database))
    }

    var body: some View {
        Group {
            if viewModel.hasAPIKey {
                chatBody
            } else {
                noKeyBody
            }
        }
        .frame(width: 340)
        .onAppear {
            viewModel.onAppear()
            viewModel.refreshKeyState()
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
            Text("Add your Anthropic API key in Settings to ask Claude about this paper.")
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
            Divider()
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
            TextField("Ask about this paper…", text: $viewModel.inputText, axis: .vertical)
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
