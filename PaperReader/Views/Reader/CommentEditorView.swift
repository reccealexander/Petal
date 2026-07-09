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
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 120)
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
        .frame(width: 320)
    }
}
