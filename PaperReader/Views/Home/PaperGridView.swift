import SwiftUI
import AppKit
import PaperReaderCore

struct PaperGridView: View {
    @ObservedObject var library: LibraryViewModel
    @ObservedObject var selection: PaperSelectionController
    let papersDirectory: URL
    let onOpen: (String) -> Void
    let onRequestDelete: (Set<String>) -> Void
    let onDeselect: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 20)]

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onDeselect)

            if library.grouping == .flat {
                flatGrid
            } else {
                groupedGrid
            }
        }
    }

    private var visibleOrderedIDs: [String] {
        if library.grouping == .flat {
            return library.papers.map(\.id)
        }
        return library.groupedPapers().flatMap { $0.papers.map(\.id) }
    }

    private var flatGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(library.papers) { paper in
                    paperCard(paper)
                }
            }
            .padding(20)
        }
    }

    private var groupedGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(library.groupedPapers(), id: \.title) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(group.title)
                            .font(.title3.bold())
                            .padding(.horizontal, 20)

                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(group.papers) { paper in
                                paperCard(paper)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }
            .padding(.vertical, 20)
        }
    }

    private func paperCard(_ paper: Paper) -> some View {
        PaperCardView(
            paper: paper,
            papersDirectory: papersDirectory,
            library: library,
            isSelected: selection.isSelected(paper.id),
            selectedIDs: selection.selectedIDs,
            onRequestDelete: onRequestDelete
        )
        .onTapGesture {
            let shiftDown = NSEvent.modifierFlags.contains(.shift)
            selection.handleTap(paper.id, shiftDown: shiftDown, orderedIDs: visibleOrderedIDs, open: onOpen)
        }
    }
}
