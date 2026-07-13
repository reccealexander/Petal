import SwiftUI

/// Content view for the `NSPopover` shown when the user clicks a highlight to
/// add or edit its comment (spec §3 Phase 1). Purely presentational: it edits
/// text locally and reports the result via callbacks — no database or PDFKit
/// dependencies.
struct CommentEditorView: View {
    /// The comment text to seed the editor with (empty string for a new comment).
    let initialText: String
    /// Whether this highlight already has a saved comment (controls the header
    /// text and whether the Delete button can appear).
    let hasExistingComment: Bool
    /// Called with the current (possibly edited) text when the user saves.
    let onSave: (String) -> Void
    /// Called when the user cancels without saving.
    let onCancel: () -> Void
    /// Called when the user deletes the comment. `nil` hides the Delete button.
    let onDelete: (() -> Void)?

    @State private var text: String
    @State private var popoverSize = CGSize(width: 320, height: 240)
    @State private var resizeStartSize: CGSize?
    @FocusState private var editorFocused: Bool

    private let minimumPopoverSize = CGSize(width: 260, height: 160)
    private let maximumPopoverSize = CGSize(width: 640, height: 520)

    init(
        initialText: String,
        hasExistingComment: Bool,
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.initialText = initialText
        self.hasExistingComment = hasExistingComment
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete
        _text = State(initialValue: initialText)
    }

    private var isTextEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(hasExistingComment ? "Edit Comment" : "Add Comment")
                .font(.headline)

            TextEditor(text: $text)
                .font(.body)
                .focused($editorFocused)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 60, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

            HStack {
                if hasExistingComment, let onDelete {
                    Button("Delete") {
                        onDelete()
                    }
                    .foregroundStyle(.red)
                }

                Spacer()

                Button("Cancel") {
                    onCancel()
                }

                Button("Save") {
                    onSave(text)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isTextEmpty)
            }
        }
        .padding(16)
        .frame(width: popoverSize.width, height: popoverSize.height)
        .overlay(alignment: .bottomTrailing) {
            ZStack {
                Rectangle()
                    .fill(Color.clear)
                Image(systemName: "arrow.down.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .help("Drag to resize")
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if resizeStartSize == nil {
                                resizeStartSize = popoverSize
                            }
                            guard let startSize = resizeStartSize else { return }
                            popoverSize = CGSize(
                                width: min(
                                    maximumPopoverSize.width,
                                    max(minimumPopoverSize.width, startSize.width + value.translation.width)
                                ),
                                height: min(
                                    maximumPopoverSize.height,
                                    max(minimumPopoverSize.height, startSize.height + value.translation.height)
                                )
                            )
                        }
                        .onEnded { _ in
                            resizeStartSize = nil
                        }
                )
                .zIndex(1)
        }
        .onAppear { DispatchQueue.main.async { editorFocused = true } }
    }
}
