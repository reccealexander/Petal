import SwiftUI

/// Spotlight-style, app-local search presented over the main library window.
struct GlobalSearchOverlay: View {
    @ObservedObject var library: LibraryViewModel
    let onSelect: (GlobalSearchResult) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var results: [GlobalSearchResult] = []
    @State private var highlightedIndex = 0
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    TextField("Search papers and notebooks", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($searchFieldFocused)
                        .onSubmit { openHighlighted() }
                }
                .padding(18)

                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                resultRow(result, highlighted: index == highlightedIndex)
                                    .onTapGesture { onSelect(result) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 360)
                    .overlay {
                        if results.isEmpty {
                            Text("No results")
                                .foregroundStyle(.secondary)
                                .padding(32)
                        }
                    }
                }
            }
            .frame(width: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
        }
        .onAppear { searchFieldFocused = true }
        .onChange(of: query) { _, newValue in
            highlightedIndex = 0
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results = []
            }
        }
        .task(id: query) {
            do {
                try await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                results = library.globalSearch(query)
            } catch {
                // A newer query cancels this debounce task.
            }
        }
        .onExitCommand(perform: onDismiss)
        .onKeyPress(.upArrow) {
            guard !results.isEmpty else { return .ignored }
            highlightedIndex = max(0, highlightedIndex - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !results.isEmpty else { return .ignored }
            highlightedIndex = min(results.count - 1, highlightedIndex + 1)
            return .handled
        }
    }

    private func openHighlighted() {
        guard results.indices.contains(highlightedIndex) else { return }
        onSelect(results[highlightedIndex])
    }

    @ViewBuilder
    private func resultRow(_ result: GlobalSearchResult, highlighted: Bool) -> some View {
        let presentation: (icon: String, title: String, type: String) = switch result {
        case .paper(_, let title): ("doc", title, "Paper")
        case .notebook(_, let name): ("folder", name, "Notebook")
        }
        HStack(spacing: 12) {
            Image(systemName: presentation.icon)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(presentation.title)
                .lineLimit(1)
            Spacer()
            Text(presentation.type)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(highlighted ? Color.accentColor.opacity(0.18) : .clear)
        )
        .contentShape(Rectangle())
    }
}
