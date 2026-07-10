import SwiftUI
import AppKit

/// Owns the app's appearance preference (System / Light / Dark) and applies it
/// live across all windows without requiring an app restart.
///
/// The preference is a non-secret UI setting, so it is persisted to
/// `UserDefaults` (unlike the Anthropic API key, which must stay Keychain-only).
@MainActor
final class AppearanceManager: ObservableObject {
    private static let defaultsKey = "appearance"

    enum Appearance: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    @Published var appearance: Appearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Self.defaultsKey)
            apply()
        }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
        self.appearance = stored.flatMap(Appearance.init(rawValue:)) ?? .system
        apply()
    }

    /// Sets `NSApp.appearance`, which live-updates every window in the app —
    /// no restart required.
    func apply() {
        switch appearance {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
