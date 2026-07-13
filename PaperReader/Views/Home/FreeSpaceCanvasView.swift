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
    @State private var graphMode = false

    // FreeSpacePaperCard's laid-out size is approximately 176 x 250 points.
    // Since `.position` uses its center, these half dimensions keep the whole
    // card inside the canvas.
    private let cardHalfSize = CGSize(width: 88, height: 125)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDeselect)

                if graphMode {
                    Canvas { context, _ in
                        for edge in sharedTagEdges(in: geo.size) {
                            var path = Path()
                            path.move(to: edge.start)
                            path.addLine(to: edge.end)
                            context.stroke(
                                path,
                                with: .color(.secondary.opacity(0.28)),
                                lineWidth: 1
                            )
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)
                }

                ForEach(Array(library.papers.enumerated()), id: \.element.id) { index, paper in
                    let position = position(for: paper, index: index, in: geo.size)
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
                            guard hasUsableSize(geo.size) else { return }
                            let constrained = clamped(newPosition, to: geo.size)
                            livePositions[paper.id] = constrained
                            library.setPaperPosition(
                                paperId: paper.id,
                                x: constrained.x,
                                y: constrained.y
                            )
                        }
                    }
                    .position(position)
                }

                graphToggle
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .zIndex(1)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onAppear { persistConstrainedPositions(in: geo.size) }
            .onChange(of: geo.size) { _, size in
                persistConstrainedPositions(in: size)
            }
            .onChange(of: library.papers) { _, _ in
                persistConstrainedPositions(in: geo.size)
            }
        }
    }

    private var graphToggle: some View {
        HStack(spacing: 2) {
            modeButton(title: "Free", icon: "rectangle.3.group", enabled: !graphMode) {
                graphMode = false
            }
            modeButton(
                title: "Graph",
                icon: "point.3.connected.trianglepath.dotted",
                enabled: graphMode
            ) {
                graphMode = true
            }
        }
        .padding(3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.2))
        )
    }

    private func modeButton(
        title: String,
        icon: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    enabled ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    private func position(for paper: Paper, index: Int, in size: CGSize) -> CGPoint {
        if let live = livePositions[paper.id] {
            return hasUsableSize(size) ? clamped(live, to: size) : live
        }
        if let x = paper.freeSpaceX, let y = paper.freeSpaceY {
            let saved = CGPoint(x: x, y: y)
            return hasUsableSize(size) ? clamped(saved, to: size) : saved
        }
        return defaultPosition(for: index, in: size)
    }

    private func defaultPosition(for index: Int, in size: CGSize) -> CGPoint {
        guard hasUsableSize(size) else { return .zero }

        let horizontalStep = cardHalfSize.width * 2 + 24
        let verticalStep = cardHalfSize.height * 2 + 24
        let availableWidth = max(0, size.width - cardHalfSize.width * 2)
        let columns = max(1, Int(availableWidth / horizontalStep) + 1)
        let point = CGPoint(
            x: cardHalfSize.width + CGFloat(index % columns) * horizontalStep,
            y: cardHalfSize.height + CGFloat(index / columns) * verticalStep
        )
        return clamped(point, to: size)
    }

    private func persistConstrainedPositions(in size: CGSize) {
        guard hasUsableSize(size) else { return }

        for (index, paper) in library.papers.enumerated() {
            let saved = paper.freeSpaceX.flatMap { x in
                paper.freeSpaceY.map { y in CGPoint(x: x, y: y) }
            }
            let point = saved.map { clamped($0, to: size) }
                ?? defaultPosition(for: index, in: size)

            if let saved, saved == point {
                livePositions[paper.id] = point
                continue
            }

            livePositions[paper.id] = point
            library.setPaperPosition(paperId: paper.id, x: point.x, y: point.y)
        }
    }

    private func clamped(_ point: CGPoint, to size: CGSize) -> CGPoint {
        CGPoint(
            x: clampedCoordinate(point.x, extent: size.width, inset: cardHalfSize.width),
            y: clampedCoordinate(point.y, extent: size.height, inset: cardHalfSize.height)
        )
    }

    private func clampedCoordinate(_ value: CGFloat, extent: CGFloat, inset: CGFloat) -> CGFloat {
        guard extent > 0 else { return 0 }
        guard extent >= inset * 2 else { return extent / 2 }
        return min(max(value, inset), extent - inset)
    }

    private func hasUsableSize(_ size: CGSize) -> Bool {
        size.width > 1 && size.height > 1
    }

    private func sharedTagEdges(in size: CGSize) -> [(start: CGPoint, end: CGPoint)] {
        var edges: [(CGPoint, CGPoint)] = []
        let papers = library.papers

        for leftIndex in papers.indices {
            guard leftIndex + 1 < papers.count else { continue }
            let leftTags = Set((library.tagsByPaper[papers[leftIndex].id] ?? []).map(\.id))
            guard !leftTags.isEmpty else { continue }

            for rightIndex in (leftIndex + 1)..<papers.count {
                let rightTags = Set((library.tagsByPaper[papers[rightIndex].id] ?? []).map(\.id))
                guard !leftTags.intersection(rightTags).isEmpty else { continue }
                edges.append((
                    position(for: papers[leftIndex], index: leftIndex, in: size),
                    position(for: papers[rightIndex], index: rightIndex, in: size)
                ))
            }
        }
        return edges
    }
}

private struct FreeSpacePaperCard: View {
    private static let thumbnailSize = CGSize(width: 160, height: 200)

    let paper: Paper
    let papersDirectory: URL
    let hasNotes: Bool
    let isSelected: Bool
    let basePosition: CGPoint
    let onDragEnded: (CGPoint) -> Void

    @State private var dragOffset: CGSize = .zero
    @Environment(\.openWindow) private var openWindow
    @StateObject private var accent = AccentColorProvider()
    @EnvironmentObject private var appearance: AppearanceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                    .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        if appearance.showReadingProgress {
                            ReadingProgressBorder(fraction: paper.readingProgressFraction)
                        }
                    }

                Button {
                    openWindow(value: NotesWindowID(paperId: paper.id))
                } label: {
                    Image(systemName: "note.text")
                        .font(.caption)
                        .foregroundStyle(hasNotes ? accent.color : Color.secondary)
                        .padding(6)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .help("Open Note")
                .padding(5)

                if paper.pinnedAt != nil {
                    PinBadge()
                        .padding(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)

            Text(paper.title ?? "Untitled")
                .font(.caption)
                .lineLimit(2)
                .frame(width: Self.thumbnailSize.width, alignment: .leading)
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
        return ThumbnailImageCache.image(at: url)
    }
}
