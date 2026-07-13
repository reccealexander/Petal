import SwiftUI

struct PaperPagedLibraryView: View {
    @ObservedObject var library: LibraryViewModel
    @ObservedObject var selection: PaperSelectionController
    let papersDirectory: URL
    let onOpen: (String) -> Void
    let onRequestDelete: (Set<String>) -> Void

    @State private var currentPage: Int? = 0
    @State private var pageContentSize: CGSize = .zero
    @FocusState private var pagerFocused: Bool

    private let pages = [
        (title: "Grid", icon: "square.grid.2x2"),
        (title: "List", icon: "list.bullet"),
        (title: "Free Space", icon: "rectangle.3.group")
    ]

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        page(index: 0)
                            .frame(width: proxy.size.width, height: proxy.size.height - 34)
                            .id(0)
                        page(index: 1)
                            .frame(width: proxy.size.width, height: proxy.size.height - 34)
                            .id(1)
                        page(index: 2)
                            .frame(width: proxy.size.width, height: proxy.size.height - 34)
                            .id(2)
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentPage)
                .onChange(of: currentPage) { _, page in
                    guard let page, !pages.indices.contains(page) else { return }
                    currentPage = min(max(page, pages.startIndex), pages.index(before: pages.endIndex))
                }

                dotIndicator
                    .frame(height: 34)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($pagerFocused)
            .onAppear {
                pageContentSize = CGSize(width: proxy.size.width, height: proxy.size.height - 34)
                pagerFocused = true
            }
            .onChange(of: proxy.size) { _, size in
                pageContentSize = CGSize(width: size.width, height: size.height - 34)
            }
            .onKeyPress(.leftArrow) {
                handleArrow(.left)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                handleArrow(.right)
                return .handled
            }
            .onKeyPress(.upArrow) {
                handleArrow(.up)
                return .handled
            }
            .onKeyPress(.downArrow) {
                handleArrow(.down)
                return .handled
            }
            .onKeyPress(.return) {
                openKeyboardSelection()
                return .handled
            }
            .onKeyPress(.escape) {
                guard !selection.selectedIDs.isEmpty else { return .ignored }
                selection.deselectAll()
                return .handled
            }
        }
    }

    private enum ArrowDirection {
        case left, right, up, down
    }

    private func handleArrow(_ direction: ArrowDirection) {
        let papers = library.papers
        guard let first = papers.first else { return }

        guard selection.selectedIDs.count == 1,
              let selectedID = selection.selectedIDs.first else {
            if selection.selectedIDs.isEmpty {
                selection.selectOnly(first.id)
            }
            return
        }

        let targetID: String?
        switch currentPage ?? 0 {
        case 0:
            switch direction {
            case .left:
                targetID = adjacentID(to: selectedID, offset: -1)
            case .right:
                targetID = adjacentID(to: selectedID, offset: 1)
            case .up:
                targetID = adjacentID(to: selectedID, offset: -gridColumnCount)
            case .down:
                targetID = adjacentID(to: selectedID, offset: gridColumnCount)
            }
        case 1:
            targetID = direction == .up
                ? adjacentID(to: selectedID, offset: -1)
                : direction == .down ? adjacentID(to: selectedID, offset: 1) : nil
        case 2:
            targetID = direction == .left
                ? spatiallyAdjacentID(to: selectedID, movingRight: false)
                : direction == .right ? spatiallyAdjacentID(to: selectedID, movingRight: true) : nil
        default:
            targetID = nil
        }

        if let targetID {
            selection.selectOnly(targetID)
        }
    }

    /// Mirrors PaperGridView's 20-point horizontal padding and adaptive
    /// GridItem(minimum: 180, spacing: 20) column rule.
    private var gridColumnCount: Int {
        let minimumItemWidth: CGFloat = 180
        let spacing: CGFloat = 20
        let horizontalPadding: CGFloat = 20
        let contentWidth = max(0, pageContentSize.width - horizontalPadding * 2)
        return max(1, Int(floor((contentWidth + spacing) / (minimumItemWidth + spacing))))
    }

    private func adjacentID(to selectedID: String, offset: Int) -> String? {
        guard let index = library.papers.firstIndex(where: { $0.id == selectedID }) else {
            return library.papers.first?.id
        }
        let target = index + offset
        guard library.papers.indices.contains(target) else { return nil }
        return library.papers[target].id
    }

    /// Chooses the Euclidean-nearest card whose center is strictly on the
    /// requested horizontal side. Ties retain `library.papers` order.
    private func spatiallyAdjacentID(to selectedID: String, movingRight: Bool) -> String? {
        let positions = freeSpacePositions()
        guard let origin = positions[selectedID] else { return library.papers.first?.id }

        return library.papers
            .filter { paper in
                guard let point = positions[paper.id], paper.id != selectedID else { return false }
                return movingRight ? point.x > origin.x : point.x < origin.x
            }
            .min { lhs, rhs in
                guard let left = positions[lhs.id], let right = positions[rhs.id] else { return false }
                return squaredDistance(from: origin, to: left) < squaredDistance(from: origin, to: right)
            }?
            .id
    }

    /// Mirrors FreeSpaceCanvasView's saved-position and default-grid rules.
    private func freeSpacePositions() -> [String: CGPoint] {
        Dictionary(uniqueKeysWithValues: library.papers.enumerated().map { index, paper in
            let point: CGPoint
            if let x = paper.freeSpaceX, let y = paper.freeSpaceY {
                point = clampedFreeSpacePoint(CGPoint(x: x, y: y))
            } else {
                point = defaultFreeSpacePoint(for: index)
            }
            return (paper.id, point)
        })
    }

    private func defaultFreeSpacePoint(for index: Int) -> CGPoint {
        guard pageContentSize.width > 1, pageContentSize.height > 1 else { return .zero }
        let horizontalStep: CGFloat = 162
        let verticalStep: CGFloat = 214
        let availableWidth = max(0, pageContentSize.width - 138)
        let columns = max(1, Int(availableWidth / horizontalStep) + 1)
        return clampedFreeSpacePoint(CGPoint(
            x: 69 + CGFloat(index % columns) * horizontalStep,
            y: 95 + CGFloat(index / columns) * verticalStep
        ))
    }

    private func clampedFreeSpacePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: clampedCoordinate(point.x, extent: pageContentSize.width, inset: 69),
            y: clampedCoordinate(point.y, extent: pageContentSize.height, inset: 95)
        )
    }

    private func clampedCoordinate(_ value: CGFloat, extent: CGFloat, inset: CGFloat) -> CGFloat {
        guard extent > 0 else { return 0 }
        guard extent >= inset * 2 else { return extent / 2 }
        return min(max(value, inset), extent - inset)
    }

    private func squaredDistance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let dx = rhs.x - lhs.x
        let dy = rhs.y - lhs.y
        return dx * dx + dy * dy
    }

    private func openKeyboardSelection() {
        guard selection.selectedIDs.count == 1,
              let selectedID = selection.selectedIDs.first else { return }
        onOpen(selectedID)
    }

    @ViewBuilder
    private func page(index: Int) -> some View {
        switch index {
        case 0:
            PaperGridView(
                library: library,
                selection: selection,
                papersDirectory: papersDirectory,
                onOpen: onOpen,
                onRequestDelete: onRequestDelete,
                onDeselect: selection.deselectAll
            )
        case 1:
            PaperListView(
                library: library,
                selection: selection,
                onOpen: onOpen,
                onRequestDelete: onRequestDelete,
                onDeselect: selection.deselectAll
            )
        case 2:
            FreeSpaceCanvasView(
                library: library,
                selection: selection,
                papersDirectory: papersDirectory,
                onOpen: onOpen,
                onRequestDelete: onRequestDelete,
                onDeselect: selection.deselectAll
            )
        default:
            FreeSpaceCanvasView(
                library: library,
                selection: selection,
                papersDirectory: papersDirectory,
                onOpen: onOpen,
                onRequestDelete: onRequestDelete,
                onDeselect: selection.deselectAll
            )
        }
    }

    private var dotIndicator: some View {
        HStack(spacing: 10) {
            ForEach(pages.indices, id: \.self) { index in
                Button {
                    currentPage = index
                } label: {
                    Circle()
                        .fill((currentPage ?? 0) == index ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help(pages[index].title)
            }
        }
    }
}
