import SwiftUI
import AppKit
import PetalCore

struct PaperInteractionShell<Content: View>: View {
    let paper: Paper
    @ObservedObject var library: LibraryViewModel
    @ObservedObject var selection: PaperSelectionController
    let orderedIDs: [String]
    let onOpen: (String) -> Void
    let onRequestDelete: (Set<String>) -> Void
    @ViewBuilder var content: (Bool) -> Content

    @State private var isCitationPresented = false

    private var idsToDelete: Set<String> {
        let isSelected = selection.isSelected(paper.id)
        return (isSelected && selection.selectedIDs.count > 1) ? selection.selectedIDs : [paper.id]
    }

    private var idsToMove: Set<String> {
        let isSelected = selection.isSelected(paper.id)
        return (isSelected && selection.selectedIDs.count > 1) ? selection.selectedIDs : [paper.id]
    }

    var body: some View {
        content(selection.isSelected(paper.id))
            .contentShape(Rectangle())
            .onTapGesture {
                let shiftDown = NSEvent.modifierFlags.contains(.shift)
                selection.handleTap(paper.id, shiftDown: shiftDown, orderedIDs: orderedIDs, open: onOpen)
            }
            .contextMenu {
                Button(paper.pinnedAt == nil ? "Pin" : "Unpin") {
                    library.setPaperPinned(paperId: paper.id, pinned: paper.pinnedAt == nil)
                }
                Menu("Reading Status") {
                    ForEach(ReadingStatus.allCases) { status in
                        Button {
                            library.setReadingStatus(paperId: paper.id, status: status)
                        } label: {
                            Label(status.label, systemImage: status.symbol)
                        }
                    }
                }
                PaperMoveMenu(library: library, paperIDs: idsToMove)
                Button("Cite…") {
                    isCitationPresented = true
                }
                Divider()
                Button(idsToDelete.count > 1 ? "Delete \(idsToDelete.count) Papers…" : "Delete Paper…", role: .destructive) {
                    onRequestDelete(idsToDelete)
                }
            }
            .popover(isPresented: $isCitationPresented, arrowEdge: .trailing) {
                CitationView(paper: paper)
            }
    }
}
