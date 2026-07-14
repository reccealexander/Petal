import SwiftUI
import AppKit
import PetalCore

/// A compact "Cite" surface (Zotero-style) presented as a popover from a paper
/// card, list row, canvas item, or the reader toolbar. Shows a style picker, the
/// formatted citation in a selectable area, and a Copy button. When the paper
/// carries a DOI/arXiv id it enriches the citation from CrossRef/arXiv in the
/// background, falling back to the stored metadata so it always works offline.
struct CitationView: View {
    let paper: Paper

    @State private var style: CitationStyle
    @State private var metadata: CitationMetadata
    @State private var isEnriching = false
    @State private var didEnrich = false
    @State private var didCopy = false

    init(paper: Paper, initialStyle: CitationStyle = .apa) {
        self.paper = paper
        _style = State(initialValue: initialStyle)
        _metadata = State(initialValue: CitationMetadata(paper: paper))
    }

    /// The formatted citation for the selected style, including the formatter's
    /// `*…*` italic markers.
    private var citation: String {
        CitationFormatter.format(metadata, style: style)
    }

    /// Plain-text form used for the on-screen selection copy and the Copy
    /// button; strips the emphasis markers so nothing literal ends up pasted.
    private var plainCitation: String {
        citation.replacingOccurrences(of: "*", with: "")
    }

    private var isMonospaced: Bool {
        style == .bibtex || style == .ris
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Picker("Citation style", selection: $style) {
                ForEach(CitationStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            citationTextView

            HStack {
                if didEnrich {
                    Label("Enriched from CrossRef/arXiv", systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: copy) {
                    Label(didCopy ? "Copied" : "Copy Citation",
                          systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
        .padding(16)
        .frame(width: 440)
        .task { await enrich() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Cite")
                .font(.headline)
            Spacer()
            if isEnriching {
                ProgressView()
                    .controlSize(.small)
                Text("Fetching metadata…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var citationTextView: some View {
        ScrollView {
            citationText
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .padding(10)
        }
        .frame(minHeight: 96, maxHeight: 220)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.2))
        )
    }

    @ViewBuilder
    private var citationText: some View {
        if isMonospaced {
            // BibTeX/RIS are structural — render verbatim in a monospaced font.
            Text(plainCitation)
                .font(.system(.callout, design: .monospaced))
        } else if let attributed = try? AttributedString(
            markdown: citation,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            // Prose styles: render the `*…*` markers as italics; selection still
            // copies clean text.
            Text(attributed)
                .font(.callout)
        } else {
            Text(plainCitation)
                .font(.callout)
        }
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(plainCitation, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            didCopy = false
        }
    }

    private func enrich() async {
        guard !didEnrich, CitationMetadataService.canEnrich(paper) else { return }
        isEnriching = true
        // Build the Sendable baseline on the main actor, then hand only that to
        // the background service (never the non-Sendable `Paper`).
        let baseline = CitationMetadata(paper: paper)
        let enriched = await CitationMetadataService().enrichedMetadata(from: baseline)
        // Only surface the "enriched" badge when the lookup actually added
        // something beyond the offline baseline.
        metadata = enriched
        didEnrich = enriched != baseline
        isEnriching = false
    }
}
