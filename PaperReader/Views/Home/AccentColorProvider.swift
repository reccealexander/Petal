import SwiftUI
import AppKit

@MainActor
final class AccentColorProvider: ObservableObject {
    @Published private(set) var color: Color = Color(nsColor: .controlAccentColor)

    private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    func refresh() {
        color = Color(nsColor: .controlAccentColor)
    }
}

struct PaperNoteBadge: View {
    @StateObject private var accent = AccentColorProvider()

    var body: some View {
        Image(systemName: "note.text")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(5)
            .background(Circle().fill(accent.color))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .help("Has notes")
    }
}
