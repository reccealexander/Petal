import SwiftUI
import AppKit
import PetalCore

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

struct PinBadge: View {
    @StateObject private var accent = AccentColorProvider()

    var body: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(accent.color)
            .padding(5)
            .background(Circle().fill(.ultraThinMaterial))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .help("Pinned")
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

extension Paper {
    var readingProgressFraction: Double {
        guard let pageCount, pageCount > 0 else { return 0 }
        return min(max(Double(furthestPageRead) / Double(pageCount), 0), 1)
    }
}

/// Draws a thumbnail's completed perimeter from top-left, clockwise.
struct ReadingProgressBorder: View {
    let fraction: Double
    @StateObject private var accent = AccentColorProvider()

    var body: some View {
        if fraction > 0 {
            GeometryReader { geometry in
                let inset: CGFloat = 1.5
                Path { path in
                    let rect = CGRect(origin: .zero, size: geometry.size).insetBy(dx: inset, dy: inset)
                    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                    path.closeSubpath()
                }
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(accent.color, style: StrokeStyle(lineWidth: 3, lineCap: .butt, lineJoin: .miter))
            }
            .allowsHitTesting(false)
        }
    }
}

struct CompactReadingProgress: View {
    let fraction: Double
    @StateObject private var accent = AccentColorProvider()

    var body: some View {
        if fraction > 0 {
            GeometryReader { geometry in
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(accent.color)
                            .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                    }
            }
            .frame(width: 40, height: 5)
            .accessibilityLabel("Reading progress")
            .accessibilityValue("\(Int(min(max(fraction, 0), 1) * 100)) percent")
        }
    }
}
