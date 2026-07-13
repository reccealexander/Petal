import SwiftUI
import PaperReaderCore

struct PaperListView: View {
    @ObservedObject var library: LibraryViewModel
    @ObservedObject var selection: PaperSelectionController
    let onOpen: (String) -> Void
    let onRequestDelete: (Set<String>) -> Void
    let onDeselect: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onDeselect)

                    LazyVStack(alignment: .leading, spacing: 8) {
                        if library.grouping == .flat {
                            ForEach(library.papers) { paper in
                                row(paper, orderedIDs: library.papers.map(\.id))
                            }
                        } else {
                            ForEach(library.groupedPapers(), id: \.title) { group in
                                Text(group.title)
                                    .font(.headline)
                                    .padding(.horizontal, 20)
                                    .padding(.top, 12)

                                ForEach(group.papers) { paper in
                                    row(paper, orderedIDs: visibleOrderedIDs)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 16)
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

    private func row(_ paper: Paper, orderedIDs: [String]) -> some View {
        PaperInteractionShell(
            paper: paper,
            library: library,
            selection: selection,
            orderedIDs: orderedIDs,
            onOpen: onOpen,
            onRequestDelete: onRequestDelete
        ) { isSelected in
            PaperListRow(
                paper: paper,
                tags: library.tagsByPaper[paper.id] ?? [],
                hasNotes: library.papersWithNotes.contains(paper.id),
                isSelected: isSelected
            )
        }
        .padding(.horizontal, 16)
    }
}

private struct PaperListRow: View {
    let paper: Paper
    let tags: [Tag]
    let hasNotes: Bool
    let isSelected: Bool
    @Environment(\.openWindow) private var openWindow
    @StateObject private var accent = AccentColorProvider()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: paper.pinnedAt == nil ? "doc.text" : "pin.fill")
                .foregroundStyle(paper.pinnedAt == nil ? .secondary : Color.accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(paper.title ?? "Untitled")
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if let count = paper.pageCount {
                        Text(count == 1 ? "1 page" : "\(count) pages")
                    }
                    if !tags.isEmpty {
                        Text(tags.map(\.name).joined(separator: ", "))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)

            ReadingStatusBadge(status: ReadingStatus(rawValueOrUnread: paper.readingStatus))

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
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.12), lineWidth: isSelected ? 1.5 : 1)
        )
    }
}
