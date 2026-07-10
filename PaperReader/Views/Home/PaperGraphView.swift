import SwiftUI
import PaperReaderCore

struct PaperGraphView: View {
    @ObservedObject var library: LibraryViewModel
    @ObservedObject var selection: PaperSelectionController
    let onOpen: (String) -> Void
    let onRequestDelete: (Set<String>) -> Void
    let onDeselect: () -> Void

    private let canvasSize = CGSize(width: 1800, height: 1200)

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDeselect)

                Canvas { context, _ in
                    for edge in sharedTagEdges {
                        var path = Path()
                        path.move(to: edge.start)
                        path.addLine(to: edge.end)
                        context.stroke(path, with: .color(.secondary.opacity(0.28)), lineWidth: 1)
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)

                ForEach(Array(library.papers.enumerated()), id: \.element.id) { index, paper in
                    let position = position(for: paper, index: index)
                    PaperInteractionShell(
                        paper: paper,
                        library: library,
                        selection: selection,
                        orderedIDs: library.papers.map(\.id),
                        onOpen: onOpen,
                        onRequestDelete: onRequestDelete
                    ) { isSelected in
                        GraphPaperNode(
                            paper: paper,
                            hasNotes: library.papersWithNotes.contains(paper.id),
                            isSelected: isSelected
                        )
                    }
                    .position(position)
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
        }
    }

    private var sharedTagEdges: [(start: CGPoint, end: CGPoint)] {
        var edges: [(CGPoint, CGPoint)] = []
        let papers = library.papers
        for leftIndex in papers.indices {
            guard leftIndex + 1 < papers.count else { continue }
            let leftTags = Set((library.tagsByPaper[papers[leftIndex].id] ?? []).map(\.id))
            guard !leftTags.isEmpty else { continue }

            for rightIndex in (leftIndex + 1)..<papers.count {
                let rightTags = Set((library.tagsByPaper[papers[rightIndex].id] ?? []).map(\.id))
                if !leftTags.intersection(rightTags).isEmpty {
                    edges.append((
                        position(for: papers[leftIndex], index: leftIndex),
                        position(for: papers[rightIndex], index: rightIndex)
                    ))
                }
            }
        }
        return edges
    }

    private func position(for paper: Paper, index: Int) -> CGPoint {
        if let x = paper.freeSpaceX, let y = paper.freeSpaceY {
            return CGPoint(x: x, y: y)
        }

        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let radius = min(canvasSize.width, canvasSize.height) * 0.36
        let count = max(library.papers.count, 1)
        let angle = (CGFloat(index) / CGFloat(count)) * 2 * .pi - (.pi / 2)
        return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }
}

private struct GraphPaperNode: View {
    let paper: Paper
    let hasNotes: Bool
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(paper.pinnedAt == nil ? Color.accentColor.opacity(0.82) : Color.orange.opacity(0.88))
                    .frame(width: 46, height: 46)
                    .overlay(
                        Image(systemName: paper.pinnedAt == nil ? "doc.text" : "pin.fill")
                            .foregroundStyle(.white)
                    )

                if hasNotes {
                    PaperNoteBadge()
                        .offset(x: 12, y: 22)
                }
            }

            Text(paper.title ?? "Untitled")
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 120)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.background.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: isSelected ? 2 : 1)
        )
    }
}
