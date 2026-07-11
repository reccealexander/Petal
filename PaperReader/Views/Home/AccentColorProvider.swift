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

enum ReadingStatus: String, CaseIterable, Identifiable {
    case unread
    case inProgress = "in_progress"
    case read

    var id: String { rawValue }

    init(rawValueOrUnread value: String) {
        self = ReadingStatus(rawValue: value) ?? .unread
    }

    var label: String {
        switch self {
        case .unread: return "Unread"
        case .inProgress: return "In Progress"
        case .read: return "Read"
        }
    }

    var symbol: String {
        switch self {
        case .unread: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .read: return "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .unread: return .secondary
        case .inProgress: return .accentColor
        case .read: return .green
        }
    }
}

struct ReadingStatusBadge: View {
    let status: ReadingStatus

    var body: some View {
        Image(systemName: status.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(status.color)
            .padding(5)
            .background(Circle().fill(.ultraThinMaterial))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .help(status.label)
    }
}
