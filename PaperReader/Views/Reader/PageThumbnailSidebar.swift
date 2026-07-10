import SwiftUI

/// Collapsible left-side page thumbnail sidebar for the PDF reader, like
/// Preview.app (Session 6 Part A): a scrollable column of page thumbnails,
/// the current page highlighted and kept in sync as the user scrolls the
/// main view, and click-a-thumbnail-to-jump.
struct PageThumbnailSidebar: View {
    @ObservedObject var provider: PageThumbnailProvider
    @ObservedObject var model: PDFReaderModel
    @ObservedObject var bookmarkStore: PageBookmarkStore
    @StateObject private var accent = AccentColorProvider()

    static let width: CGFloat = 180

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 12) {
                    ForEach(0..<provider.pageCount, id: \.self) { index in
                        PageThumbnailRow(
                            index: index,
                            isCurrent: index == model.currentPageIndex,
                            image: provider.thumbnail(forPage: index),
                            isBookmarked: bookmarkStore.bookmarkedPages.contains(index),
                            accentColor: accent.color,
                            toggleBookmark: {
                                bookmarkStore.toggle(page: index)
                            }
                        )
                        .id(index)
                        .onTapGesture {
                            model.goToPage(index)
                        }
                        .onAppear {
                            provider.requestThumbnail(forPage: index)
                        }
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 10)
            }
            .onChange(of: model.currentPageIndex) { _, newValue in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .frame(width: Self.width)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// A single thumbnail row: the page image (or a placeholder while it loads)
/// plus a page-number label, outlined when it's the current page.
private struct PageThumbnailRow: View {
    let index: Int
    let isCurrent: Bool
    let image: NSImage?
    let isBookmarked: Bool
    let accentColor: Color
    let toggleBookmark: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.15))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .cornerRadius(2)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

                Button(action: toggleBookmark) {
                    Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isBookmarked ? accentColor : Color.secondary.opacity(0.7))
                        .frame(width: 26, height: 26)
                        .background(
                            Circle()
                                .fill(Color(nsColor: .windowBackgroundColor).opacity(isBookmarked ? 0.9 : 0.72))
                        )
                }
                .buttonStyle(.plain)
                .help(isBookmarked ? "Remove bookmark" : "Bookmark page")
                .padding(6)
            }
            .frame(width: 140, height: 175)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isCurrent ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isCurrent ? 2.5 : 1)
            )

            Text("\(index + 1)")
                .font(.caption)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                .fontWeight(isCurrent ? .semibold : .regular)
        }
        .contentShape(Rectangle())
    }
}
