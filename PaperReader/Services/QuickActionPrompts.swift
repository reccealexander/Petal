import Foundation

/// A one-tap quick action offered by the Claude side panel (Session 7 Part C).
/// The first three are only meaningful with a live PDF selection/highlight
/// (paper scope); the last three operate over the whole notebook (notebook
/// scope). `ClaudePanelView` decides which set to show based on the active
/// `ClaudeChatScope`.
public enum QuickAction: String, CaseIterable, Identifiable, Sendable {
    case explainEquation
    case summarizeSection
    case explainHighlight
    case relateToNotebook
    case findConnections
    case summarizeNotebook

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .explainEquation: return "Explain this equation"
        case .summarizeSection: return "Summarize this section"
        case .explainHighlight: return "Explain this highlight"
        case .relateToNotebook: return "Relate to other papers"
        case .findConnections: return "Find connections"
        case .summarizeNotebook: return "Summarize this notebook"
        }
    }

    public var systemImage: String {
        switch self {
        case .explainEquation: return "function"
        case .summarizeSection: return "text.redaction"
        case .explainHighlight: return "highlighter"
        case .relateToNotebook: return "arrow.triangle.branch"
        case .findConnections: return "link"
        case .summarizeNotebook: return "list.bullet.rectangle.portrait"
        }
    }

    /// The three notebook-scope actions vs. the three paper-scope actions.
    public var isNotebookAction: Bool {
        switch self {
        case .explainEquation, .summarizeSection, .explainHighlight:
            return false
        case .relateToNotebook, .findConnections, .summarizeNotebook:
            return true
        }
    }

    /// The ordered set of actions to show for the paper scope.
    public static let paperActions: [QuickAction] = [.explainEquation, .summarizeSection, .explainHighlight]

    /// The ordered set of actions to show for the notebook scope.
    public static let notebookActions: [QuickAction] = [.relateToNotebook, .findConnections, .summarizeNotebook]
}

/// The live context a quick action can draw on, assembled by the view from
/// the reader's PDFKit coordinator (paper scope) and/or the active
/// `ClaudeChatScope` (notebook scope). Every field is optional — quick
/// actions degrade gracefully (and report why) when a piece is missing.
public struct QuickActionContext: Sendable {
    /// The current PDF text selection, if any.
    public var selection: String?
    /// Text surrounding the selection — approximated here by the current
    /// page's full text, which gives Claude enough to disambiguate an
    /// equation or fragment without a real "section" extractor.
    public var surrounding: String?
    /// The current page's full text, used as a summarization fallback when
    /// there's no selection.
    public var pageText: String?
    /// The text of the highlight the user most recently opened/selected.
    public var highlightText: String?
    /// The comment body attached to that highlight, if any.
    public var commentText: String?
    /// The current paper's title, used as a relate-to-notebook fallback.
    public var paperTitle: String?
    /// The active notebook's name (informational; the system prompt already
    /// carries full notebook context).
    public var notebookName: String?

    public init(
        selection: String? = nil,
        surrounding: String? = nil,
        pageText: String? = nil,
        highlightText: String? = nil,
        commentText: String? = nil,
        paperTitle: String? = nil,
        notebookName: String? = nil
    ) {
        self.selection = selection
        self.surrounding = surrounding
        self.pageText = pageText
        self.highlightText = highlightText
        self.commentText = commentText
        self.paperTitle = paperTitle
        self.notebookName = notebookName
    }
}

/// Builds the USER-facing chat message a quick action inserts before
/// streaming Claude's reply, and explains why an action is unavailable when
/// it is. Kept free of SwiftUI/DB so the templates are unit-testable and
/// live in exactly one place (spec: "prompt templates ONLY in this file").
public enum QuickActionPrompts {
    /// The composed user message for `action` given `context`, or `nil` if
    /// the action isn't available (the caller should show `unavailableReason`
    /// instead of sending anything).
    public static func userMessage(for action: QuickAction, context: QuickActionContext) -> String? {
        switch action {
        case .explainEquation:
            guard let selection = nonEmpty(context.selection) else { return nil }
            let surrounding = context.surrounding ?? ""
            return """
            Explain this equation / expression from the paper, step by step:

            "\(selection)"

            Use the surrounding context if helpful:
            \(surrounding)
            """

        case .summarizeSection:
            guard let text = nonEmpty(context.selection) ?? nonEmpty(context.pageText) else { return nil }
            return "Summarize this section of the paper concisely:\n\n\(text)"

        case .explainHighlight:
            guard let highlight = nonEmpty(context.highlightText) else { return nil }
            var message = "Explain this highlight from the paper and what it means in context:\n\nHighlight: \"\(highlight)\""
            if let comment = nonEmpty(context.commentText) {
                message += "\nMy comment: \(comment)"
            }
            return message

        case .relateToNotebook:
            let startingPoint: String
            if let selection = nonEmpty(context.selection) {
                startingPoint = selection
            } else if let highlight = nonEmpty(context.highlightText) {
                startingPoint = highlight
            } else if let title = nonEmpty(context.paperTitle) {
                startingPoint = "the paper \"\(title)\""
            } else {
                return nil
            }
            return "How does this relate to the other papers in this notebook? Starting point: \(startingPoint). Point out connections, agreements, and contradictions."

        case .findConnections:
            return "Look across all the papers, highlights, comments, and notes in this notebook. Identify recurring themes, methods, contradictions, and open questions."

        case .summarizeNotebook:
            return "Give a structured summary of this notebook: the papers it contains, the main themes across them, and the key points from my highlights, comments, and notes."
        }
    }

    /// A short human explanation of why `action` is unavailable given
    /// `context`, for the disabled button's tooltip. Returns `nil` if the
    /// action is actually available (or requires no context).
    public static func unavailableReason(for action: QuickAction, context: QuickActionContext) -> String? {
        switch action {
        case .explainEquation:
            guard nonEmpty(context.selection) == nil else { return nil }
            return "Select the equation or text in the PDF first."
        case .summarizeSection:
            guard nonEmpty(context.selection) == nil, nonEmpty(context.pageText) == nil else { return nil }
            return "Open a page or make a selection first."
        case .explainHighlight:
            guard nonEmpty(context.highlightText) == nil else { return nil }
            return "Select or open a highlight/comment first."
        case .relateToNotebook:
            guard nonEmpty(context.selection) == nil,
                  nonEmpty(context.highlightText) == nil,
                  nonEmpty(context.paperTitle) == nil
            else { return nil }
            return "Open a paper (or select text) to relate it to the notebook."
        case .findConnections, .summarizeNotebook:
            return nil
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
