import SwiftUI

struct HelpTip: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let shortcut: String?

    init(_ title: String, detail: String, shortcut: String? = nil) {
        self.title = title
        self.detail = detail
        self.shortcut = shortcut
    }
}

struct HelpSection: Identifiable {
    let id = UUID()
    let title: String
    let tips: [HelpTip]
}

struct QuickTipsView: View {
    /// Add help for future features here; the view below needs no changes.
    static let sections: [HelpSection] = [
        HelpSection(title: "Reading & Annotation", tips: [
            HelpTip("Highlight text", detail: "Select text in a PDF, then choose a color in the reader toolbar to highlight it."),
            HelpTip("Comment on a highlight", detail: "Click a highlight to open its popover, where you can add or edit a comment."),
            HelpTip("Move between pages", detail: "Toggle the page-thumbnail sidebar from the reader toolbar. It follows your scroll, and clicking a thumbnail jumps to that page."),
            HelpTip("Bookmark a page", detail: "Click the bookmark ribbon on a page thumbnail. The ribbon uses your accent color while that page is bookmarked."),
            HelpTip("Read at native size", detail: "PDFs open using their native page size so text and figures retain their intended scale.")
        ]),
        HelpSection(title: "Notes", tips: [
            HelpTip("Open detached notes", detail: "Click the note button on a paper card to open that paper’s notes in a separate window."),
            HelpTip("Link a highlight", detail: "Insert a highlight reference into a note to create a clickable link back to the source passage."),
            HelpTip("Return to the PDF", detail: "Choose Open PDF from a note to open its paper and jump to the referenced page."),
            HelpTip("Delete a note", detail: "Delete a note when you no longer need it; its detached window closes as well."),
            HelpTip("Browse every note", detail: "Choose Notes at the top of the library sidebar to see notes from all papers in one place.")
        ]),
        HelpSection(title: "Organization", tips: [
            HelpTip("Build nested notebooks", detail: "Create notebooks at any depth in the sidebar tree, then drag papers or notebooks to reorganize them."),
            HelpTip("Add consistent tags", detail: "Tag papers to connect related work. Autocomplete helps you reuse existing tags and avoid near-duplicates."),
            HelpTip("Pin important items", detail: "Use the context menu to pin a paper to the top of its notebook or a notebook to the top of All Folders."),
            HelpTip("Scan All Folders", detail: "All Folders presents notebooks with stacked-paper thumbnails for a visual overview of your library."),
            HelpTip("Spot papers with notes", detail: "A notes badge appears on every paper that has notes."),
            HelpTip("Use notebook summaries", detail: "Each notebook has an AI summary, which regenerates when you add notes so it stays current.")
        ]),
        HelpSection(title: "View Modes", tips: [
            HelpTip("Choose a layout", detail: "The paper area has four modes: Grid, List, Free Space, and Graph. Switch modes with a horizontal two-finger swipe; the dots at the bottom show the active mode."),
            HelpTip("Arrange Free Space", detail: "Drag papers anywhere in Free Space. Their positions persist when you leave and return."),
            HelpTip("Explore the graph", detail: "Graph displays papers as nodes and draws edges between papers that share tags.")
        ]),
        HelpSection(title: "Selection & Windows", tips: [
            HelpTip("Select, then open", detail: "Single-click a paper card to select it. Click the already-selected card again to open it."),
            HelpTip("Select a pair", detail: "Shift-click another paper to select exactly two papers for comparison."),
            HelpTip("Open side by side", detail: "Open the selected papers together in a side-by-side reader.", shortcut: "⌘O"),
            HelpTip("Delete selected papers", detail: "Delete selected papers with confirmation. The same action is available from the context menu.", shortcut: "⌘⌫"),
            HelpTip("Join windows", detail: "Drag any two PDF reader, notes, or main library windows next to each other to join them in one split window."),
            HelpTip("Split windows apart", detail: "Choose Split out in a joined window to separate its panes into individual windows again.")
        ]),
        HelpSection(title: "Ask Gemini", tips: [
            HelpTip("Toggle the Gemini panel", detail: "In a reader, Ask Gemini answers about that paper. In the main window, it answers across the selected notebook.", shortcut: "⌘⇧A"),
            HelpTip("Start with a quick action", detail: "Use quick actions to explain an equation or highlight, summarize a section, relate material to a notebook, and more."),
            HelpTip("Connect Google AI Studio", detail: "Ask Gemini requires a Google AI Studio API key. Add yours in Preferences → API Key.")
        ]),
        HelpSection(title: "Appearance & Search", tips: [
            HelpTip("Choose an appearance", detail: "Select System, Light, or Dark in Preferences → Appearance."),
            HelpTip("Adjust transparency", detail: "The Appearance transparency slider fades the main window chrome while keeping paper cards legible."),
            HelpTip("Enter Focus Mode", detail: "Use the reader toolbar toggle to hide everything except the PDF, including other apps and windows. Exit from View → Exit Focus Mode or with Escape.", shortcut: "Esc"),
            HelpTip("Search the library", detail: "Open the search overlay to find papers and notebooks. Escape closes the overlay.", shortcut: "⇧`"),
            HelpTip("Open Preferences", detail: "Open the API Key, Appearance, and Quick Tips settings.", shortcut: "⌘,")
        ])
    ]

    var body: some View {
        List {
            ForEach(Self.sections) { section in
                Section(section.title) {
                    ForEach(section.tips) { tip in
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tip.title)
                                    .fontWeight(.semibold)
                                Text(tip.detail)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 8)

                            if let shortcut = tip.shortcut {
                                Text(shortcut)
                                    .font(.system(.callout, design: .monospaced, weight: .semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                    .accessibilityLabel("Keyboard shortcut: \(shortcut)")
                            }
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}
