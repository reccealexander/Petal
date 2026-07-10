import SwiftUI
import AppKit
import PaperReaderCore

struct FreeSpaceCanvasView: View {
    @ObservedObject var library: LibraryViewModel
    @ObservedObject var selection: PaperSelectionController
    let papersDirectory: URL
    let onOpen: (String) -> Void
    let onRequestDelete: (Set<String>) -> Void
    let onDeselect: () -> Void

    @State private var livePositions: [String: CGPoint] = [:]

    private let canvasSize = CGSize(width: 2400, height: 1800)

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDeselect)

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
                        FreeSpacePaperCard(
                            paper: paper,
                            papersDirectory: papersDirectory,
                            hasNotes: library.papersWithNotes.contains(paper.id),
                            isSelected: isSelected,
                            basePosition: position
                        ) { newPosition in
                            livePositions[paper.id] = newPosition
                            library.setPaperPosition(paperId: paper.id, x: newPosition.x, y: newPosition.y)
                        }
                    }
                    .position(position)
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
        }
        .onAppear(perform: persistDefaultPositions)
        .onChange(of: library.papers) { _, _ in persistDefaultPositions() }
    }

    private func position(for paper: Paper, index: Int) -> CGPoint {
        if let live = livePositions[paper.id] {
            return live
        }
        if let x = paper.freeSpaceX, let y = paper.freeSpaceY {
            return CGPoint(x: x, y: y)
        }
        return defaultPosition(for: index)
    }

    private func defaultPosition(for index: Int) -> CGPoint {
        let columns = 8
        let x = 110 + CGFloat(index % columns) * 210
        let y = 130 + CGFloat(index / columns) * 220
        return CGPoint(x: x, y: y)
    }

    private func persistDefaultPositions() {
        for (index, paper) in library.papers.enumerated() where paper.freeSpaceX == nil || paper.freeSpaceY == nil {
            let point = defaultPosition(for: index)
            livePositions[paper.id] = point
            library.setPaperPosition(paperId: paper.id, x: point.x, y: point.y)
        }
    }
}

private struct FreeSpacePaperCard: View {
    let paper: Paper
    let papersDirectory: URL
    let hasNotes: Bool
    let isSelected: Bool
    let basePosition: CGPoint
    let onDragEnded: (CGPoint) -> Void

    @State private var dragOffset: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                    .frame(width: 112, height: 142)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                if hasNotes {
                    PaperNoteBadge()
                        .padding(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }

            Text(paper.title ?? "Untitled")
                .font(.caption)
                .lineLimit(2)
                .frame(width: 122, alignment: .leading)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: isSelected ? 2 : 1)
        )
        .offset(dragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragOffset = value.translation
                }
                .onEnded { value in
                    let newPosition = CGPoint(
                        x: basePosition.x + value.translation.width,
                        y: basePosition.y + value.translation.height
                    )
                    dragOffset = .zero
                    onDragEnded(newPosition)
                }
        )
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = loadThumbnailImage() {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .overlay(
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                )
        }
    }

    private func loadThumbnailImage() -> NSImage? {
        let url = PDFImportService.thumbnailURL(for: paper, in: papersDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }
}
