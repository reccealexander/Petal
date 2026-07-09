import SwiftUI
import AppKit
import PaperReaderCore

/// A single card in the Home grid (spec §3 Phase 1): thumbnail, title, and page
/// count for one imported `Paper`. The whole card reports `.contentShape(Rectangle())`
/// so a parent view can attach tap/selection handling over its full bounds.
struct PaperCardView: View {
    let paper: Paper
    let papersDirectory: URL

    init(paper: Paper, papersDirectory: URL) {
        self.paper = paper
        self.papersDirectory = papersDirectory
    }

    private static let cardWidth: CGFloat = 160
    private static let thumbnailHeight: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnailView
                .frame(width: Self.cardWidth, height: Self.thumbnailHeight)

            Text(paper.title ?? "Untitled")
                .font(.headline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let count = paper.pageCount {
                Text(count == 1 ? "1 page" : "\(count) pages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: Self.cardWidth + 24)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15))
        )
        .contentShape(Rectangle())
    }

    /// The cached page-1 thumbnail if it exists on disk, otherwise a placeholder icon.
    @ViewBuilder
    private var thumbnailView: some View {
        if let nsImage = loadThumbnailImage() {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .overlay(
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 36))
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
