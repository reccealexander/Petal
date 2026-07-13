import SwiftUI

struct PDFChapterEntry: Identifiable {
    let id: Int
    let label: String
    let pageIndex: Int
}

/// Collapsible left-side reader sidebar. It can show either page thumbnails
/// or the PDF's top-level embedded outline entries.
struct PageThumbnailSidebar: View {
    @ObservedObject var provider: PageThumbnailProvider
    @ObservedObject var model: PDFReaderModel
    @ObservedObject var bookmarkStore: PageBookmarkStore
    let chapters: [PDFChapterEntry]
    @StateObject private var accent = AccentColorProvider()
    @FocusState private var isThumbnailListFocused: Bool

    static let width: CGFloat = 180

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $model.sidebarMode) {
                ForEach(PDFReaderModel.SidebarMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            switch model.sidebarMode {
            case .thumbnails:
                thumbnails
            case .chapters:
                chapterList
            }
        }
        .frame(width: Self.width)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var thumbnails: some View {
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
                            isThumbnailListFocused = true
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
        .focusable()
        .focused($isThumbnailListFocused)
        .onKeyPress(.downArrow) {
            guard provider.pageCount > 0 else { return .ignored }
            let target = min(provider.pageCount - 1, model.currentPageIndex + 1)
            model.goToPage(target)
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard provider.pageCount > 0 else { return .ignored }
            let target = max(0, model.currentPageIndex - 1)
            model.goToPage(target)
            return .handled
        }
    }

    @ViewBuilder
    private var chapterList: some View {
        if chapters.isEmpty {
            ContentUnavailableView(
                "No Chapters",
                systemImage: "list.bullet.indent",
                description: Text("No chapter data available for this paper")
            )
            .padding(12)
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(chapters) { chapter in
                        Button {
                            model.goToPage(chapter.pageIndex)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(chapter.label)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Text("\(chapter.pageIndex + 1)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            chapter.pageIndex == model.currentPageIndex
                                ? accent.color.opacity(0.16)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                    }
                }
                .padding(8)
            }
        }
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
