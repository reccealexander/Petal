import SwiftUI
import AppKit
import PaperReaderCore

/// A single card in the Home grid (spec §3 Phase 1, extended in Session 5 Part
/// A): thumbnail, title, page count, and tag chips for one imported `Paper`.
/// The whole card reports `.contentShape(Rectangle())` so a parent view can
/// attach tap/selection handling over its full bounds. The card is also a drag
/// source (`"paper:<id>"`) so it can be dropped onto a sidebar notebook.
struct PaperCardView: View {
    let paper: Paper
    let papersDirectory: URL
    @ObservedObject var library: LibraryViewModel

    @State private var isEditingTags = false
    @State private var newTagText = ""
    @Environment(\.openWindow) private var openWindow

    init(paper: Paper, papersDirectory: URL, library: LibraryViewModel) {
        self.paper = paper
        self.papersDirectory = papersDirectory
        self.library = library
    }

    private static let cardWidth: CGFloat = 160
    private static let thumbnailHeight: CGFloat = 200

    private var tags: [Tag] {
        library.tagsByPaper[paper.id] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                thumbnailView
                    .frame(width: Self.cardWidth, height: Self.thumbnailHeight)

                HStack(spacing: 6) {
                    openNoteButton
                    tagEditButton
                }
                .padding(6)
            }

            Text(paper.title ?? "Untitled")
                .font(.headline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let count = paper.pageCount {
                Text(count == 1 ? "1 page" : "\(count) pages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !tags.isEmpty {
                tagChipsRow
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
        .draggable("paper:\(paper.id)")
        .contextMenu {
            Button("Edit Tags…") {
                isEditingTags = true
            }
            Button("Open Note") {
                openNote()
            }
        }
    }

    /// A small, non-tap-through control that opens (or lazily creates) the
    /// paper's primary note in the existing detached notes window (spec
    /// Session 7 Part A, #5). `openWindow(value:)` brings an already-open
    /// window for the same `NotesWindowID` to the front instead of duplicating
    /// it, so this single call both creates-and-opens and "reveals if open".
    private var openNoteButton: some View {
        Button {
            openNote()
        } label: {
            Image(systemName: "note.text")
                .font(.caption)
                .padding(6)
                .background(Circle().fill(.ultraThinMaterial))
        }
        .buttonStyle(.plain)
        .help("Open Note")
    }

    private func openNote() {
        openWindow(value: NotesWindowID(paperId: paper.id))
    }

    /// A small, non-tap-through control that opens the tag editor popover
    /// without triggering the card's parent Button (used to open the reader).
    private var tagEditButton: some View {
        Button {
            isEditingTags = true
        } label: {
            Image(systemName: "tag")
                .font(.caption)
                .padding(6)
                .background(Circle().fill(.ultraThinMaterial))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isEditingTags) {
            tagEditorPopover
        }
    }

    @ViewBuilder
    private var tagChipsRow: some View {
        FlowLayout(spacing: 4) {
            ForEach(tags) { tag in
                Text(tag.name)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
        }
    }

    private var tagEditorPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tags")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            if tags.isEmpty {
                Text("No tags yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 4) {
                    ForEach(tags) { tag in
                        HStack(spacing: 4) {
                            Text(tag.name)
                                .font(.caption)
                            Button {
                                library.removeTag(tagId: tag.id, fromPaper: paper.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
            }

            TextField("Add tag", text: $newTagText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    let name = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    library.addTag(name: name, toPaper: paper.id)
                    newTagText = ""
                }
        }
        .padding(12)
        .frame(width: 220)
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
