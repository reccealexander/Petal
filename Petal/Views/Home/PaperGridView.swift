import SwiftUI
import AppKit
import PetalCore

struct PaperGridView: View {
    @ObservedObject var library: LibraryViewModel
    @ObservedObject var selection: PaperSelectionController
    let papersDirectory: URL
    let onOpen: (String) -> Void
    let onRequestDelete: (Set<String>) -> Void
    let onDeselect: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 20)]

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onDeselect)

                    if library.grouping == .flat {
                        flatGrid
                    } else {
                        groupedGrid
                    }
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
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
        LazyVGrid(columns: columns, spacing: 20) {
            let subfolders = library.selectedNotebookId.map { library.childNotebooks(of: $0) } ?? []
            ForEach(subfolders) { subfolder in
                folderCard(subfolder)
            }

            ForEach(library.papers) { paper in
                paperCard(paper)
            }
        }
        .padding(20)
    }

    private var groupedGrid: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            let subfolders = library.selectedNotebookId.map { library.childNotebooks(of: $0) } ?? []
            if !subfolders.isEmpty {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(subfolders) { subfolder in
                        folderCard(subfolder)
                    }
                }
                .padding(.horizontal, 20)
            }

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

    private func folderCard(_ notebook: Notebook) -> some View {
        let preview = library.folderPreview(notebookId: notebook.id)
        return AllFolderCard(
            notebook: notebook,
            representativePaper: preview.representative,
            paperCount: preview.count,
            papersDirectory: papersDirectory
        )
        .contentShape(Rectangle())
        .onTapGesture {
            library.selection = .notebook(notebook.id)
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
