import SwiftUI

struct PaperPagedLibraryView: View {
    @ObservedObject var library: LibraryViewModel
    @ObservedObject var selection: PaperSelectionController
    let papersDirectory: URL
    let onOpen: (String) -> Void
    let onRequestDelete: (Set<String>) -> Void

    @State private var currentPage: Int? = 0

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
        }
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
