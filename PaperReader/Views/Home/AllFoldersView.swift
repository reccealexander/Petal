import SwiftUI
import AppKit
import PaperReaderCore

struct AllFoldersView: View {
    @ObservedObject var library: LibraryViewModel
    let papersDirectory: URL
    let onOpenNotebook: (Notebook) -> Void

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 20)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(library.notebooks) { notebook in
                    let papers = library.papersUnder(notebookId: notebook.id)
                    AllFolderCard(
                        notebook: notebook,
                        representativePaper: representativePaper(from: papers),
                        paperCount: papers.count,
                        papersDirectory: papersDirectory
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onOpenNotebook(notebook)
                    }
                    .contextMenu {
                        Button(notebook.pinnedAt == nil ? "Pin" : "Unpin") {
                            library.setNotebookPinned(id: notebook.id, pinned: notebook.pinnedAt == nil)
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("All Folders")
    }

    private func representativePaper(from papers: [Paper]) -> Paper? {
        papers.first(where: { $0.pinnedAt != nil }) ?? papers.first
    }
}

private struct AllFolderCard: View {
    let notebook: Notebook
    let representativePaper: Paper?
    let paperCount: Int
    let papersDirectory: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            stackedThumbnail
                .frame(width: 152, height: 184)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(notebook.name)
                        .font(.headline)
                        .lineLimit(2)
                    if notebook.pinnedAt != nil {
                        Image(systemName: "pin.fill")
                            .foregroundStyle(Color.accentColor)
                            .font(.caption)
                    }
                }

                Text(paperCount == 1 ? "1 paper" : "\(paperCount) papers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 190, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    private var stackedThumbnail: some View {
        ZStack {
            pileSheet(offset: CGSize(width: -10, height: 10), opacity: 0.52)
            pileSheet(offset: CGSize(width: -5, height: 5), opacity: 0.72)

            Group {
                if let representativePaper, let image = thumbnail(for: representativePaper) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .background(Color.secondary.opacity(0.08))
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                        .overlay(
                            Image(systemName: "folder")
                                .font(.system(size: 38))
                                .foregroundStyle(.secondary)
                        )
                }
            }
            .frame(width: 126, height: 162)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 7, y: 3)
        }
    }

    private func pileSheet(offset: CGSize, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.secondary.opacity(0.12))
            .frame(width: 126, height: 162)
            .offset(offset)
            .shadow(color: .black.opacity(opacity * 0.16), radius: 5, y: 2)
    }

    private func thumbnail(for paper: Paper) -> NSImage? {
        let url = PDFImportService.thumbnailURL(for: paper, in: papersDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }
}
