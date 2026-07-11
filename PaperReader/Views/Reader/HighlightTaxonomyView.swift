import SwiftUI
import PaperReaderCore

enum HighlightTaxonomyScope {
    case paper(Paper)
    case notebook(Notebook)
}

@MainActor
final class HighlightTaxonomyViewModel: ObservableObject {
    struct Item: Identifiable {
        let highlight: Highlight
        let comment: Comment?
        let paper: Paper

        var id: String { highlight.id }
    }

    struct PaperGroup: Identifiable {
        let paper: Paper
        let items: [Item]

        var id: String { paper.id }
    }

    struct ColorGroup: Identifiable {
        let color: HighlightColor
        let paperGroups: [PaperGroup]

        var id: HighlightColor { color }
        var count: Int { paperGroups.reduce(0) { $0 + $1.items.count } }
    }

    @Published private(set) var groups: [ColorGroup] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    let scope: HighlightTaxonomyScope
    private let highlightRepository: HighlightRepository
    private let notebookRepository: NotebookRepository

    init(scope: HighlightTaxonomyScope, database: DatabaseManager) {
        self.scope = scope
        highlightRepository = HighlightRepository(database: database)
        notebookRepository = NotebookRepository(database: database)
    }

    func load() {
        isLoading = true
        errorMessage = nil

        do {
            let papers: [Paper]
            switch scope {
            case .paper(let paper):
                papers = [paper]
            case .notebook(let notebook):
                papers = try notebookRepository.papersUnder(notebookId: notebook.id)
            }

            var itemsByColorAndPaper: [HighlightColor: [String: [Item]]] = [:]
            for paper in papers {
                for highlight in try highlightRepository.highlights(forPaper: paper.id) {
                    // Legacy or malformed color values remain browsable in the
                    // default yellow category instead of disappearing.
                    let color = HighlightColor(rawValue: highlight.color) ?? .yellow
                    let comment = try highlightRepository.comment(forHighlight: highlight.id)
                    itemsByColorAndPaper[color, default: [:]][paper.id, default: []].append(
                        Item(highlight: highlight, comment: comment, paper: paper)
                    )
                }
            }

            // Color is deliberately the primary axis. Within each color, retain
            // the repository's paper order and each paper's page/creation order.
            groups = HighlightColor.allCases.compactMap { color in
                guard let byPaper = itemsByColorAndPaper[color] else { return nil }
                let paperGroups = papers.compactMap { paper -> PaperGroup? in
                    guard let items = byPaper[paper.id], !items.isEmpty else { return nil }
                    return PaperGroup(paper: paper, items: items)
                }
                return paperGroups.isEmpty ? nil : ColorGroup(color: color, paperGroups: paperGroups)
            }
        } catch {
            groups = []
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

@MainActor
struct HighlightTaxonomyView: View {
    @StateObject private var model: HighlightTaxonomyViewModel
    private let onJump: (_ paperId: String, _ page: Int) -> Void
    @Environment(\.dismiss) private var dismiss

    init(
        paper: Paper,
        database: DatabaseManager,
        onJump: @escaping (_ page: Int) -> Void
    ) {
        _model = StateObject(wrappedValue: HighlightTaxonomyViewModel(
            scope: .paper(paper),
            database: database
        ))
        self.onJump = { _, page in onJump(page) }
    }

    init(
        notebook: Notebook,
        database: DatabaseManager,
        onJump: @escaping (_ paperId: String, _ page: Int) -> Void
    ) {
        _model = StateObject(wrappedValue: HighlightTaxonomyViewModel(
            scope: .notebook(notebook),
            database: database
        ))
        self.onJump = onJump
    }

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView("Loading highlights…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = model.errorMessage {
                ContentUnavailableView(
                    "Couldn’t Load Highlights",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if model.groups.isEmpty {
                ContentUnavailableView("No highlights yet", systemImage: "highlighter")
            } else {
                highlightList
            }
        }
        .frame(minWidth: 520, minHeight: 440)
        .navigationTitle(title)
        .task { model.load() }
    }

    private var title: String {
        switch model.scope {
        case .paper:
            return "Highlights"
        case .notebook(let notebook):
            return "Highlights in \(notebook.name)"
        }
    }

    private var isNotebookScope: Bool {
        if case .notebook = model.scope { return true }
        return false
    }

    private var highlightList: some View {
        List {
            ForEach(model.groups) { colorGroup in
                Section {
                    ForEach(colorGroup.paperGroups) { paperGroup in
                        if isNotebookScope {
                            Text(paperGroup.paper.title ?? "Untitled")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }

                        ForEach(paperGroup.items) { item in
                            Button {
                                dismiss()
                                onJump(item.paper.id, item.highlight.page)
                            } label: {
                                HighlightTaxonomyRow(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Color(nsColor: colorGroup.color.nsColor))
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(.secondary.opacity(0.4), lineWidth: 0.5))
                        Text(colorGroup.color.displayName)
                        Text("\(colorGroup.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

private struct HighlightTaxonomyRow: View {
    let item: HighlightTaxonomyViewModel.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(item.highlight.selectedText)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("p. \(item.highlight.page + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            if let body = item.comment?.body,
               !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label {
                    Text(body)
                        .lineLimit(2)
                } icon: {
                    Image(systemName: "text.bubble")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}
