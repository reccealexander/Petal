import SwiftUI
import AppKit

/// Owns the app's appearance preference (System / Light / Dark) and applies it
/// live across all windows without requiring an app restart.
///
/// The preference is a non-secret UI setting, so it is persisted to
/// `UserDefaults` (unlike the Google AI Studio API key, which must stay Keychain-only).
@MainActor
final class AppearanceManager: ObservableObject {
    private static let defaultsKey = "appearance"
    private static let windowTransparencyDefaultsKey = "windowTransparency"
    private static let showReadingProgressDefaultsKey = "showReadingProgress"
    private static let aiPanelWidthDefaultsKey = "aiPanelWidth"
    private static let chatFontNameDefaultsKey = "chatFontName"
    private static let chatFontSizeDefaultsKey = "chatFontSize"

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

    /// Opacity of the main library window's chrome, expressed as a percentage.
    @Published var windowTransparency: Double {
        didSet {
            let clamped = min(max(windowTransparency, 1), 100)
            if clamped != windowTransparency {
                windowTransparency = clamped
                return
            }
            UserDefaults.standard.set(windowTransparency, forKey: Self.windowTransparencyDefaultsKey)
        }
    }

    @Published var showReadingProgress: Bool {
        didSet {
            UserDefaults.standard.set(showReadingProgress, forKey: Self.showReadingProgressDefaultsKey)
        }
    }

    /// Width of the trailing AI chat pane in reader windows.
    @Published var aiPanelWidth: Double {
        didSet {
            let clamped = min(max(aiPanelWidth, 280), 620)
            if clamped != aiPanelWidth {
                aiPanelWidth = clamped
                return
            }
            UserDefaults.standard.set(aiPanelWidth, forKey: Self.aiPanelWidthDefaultsKey)
        }
    }

    @Published var chatFontName: String {
        didSet {
            UserDefaults.standard.set(chatFontName, forKey: Self.chatFontNameDefaultsKey)
        }
    }

    @Published var chatFontSize: Double {
        didSet {
            let clamped = min(max(chatFontSize, 10), 28)
            if clamped != chatFontSize {
                chatFontSize = clamped
                return
            }
            UserDefaults.standard.set(chatFontSize, forKey: Self.chatFontSizeDefaultsKey)
        }
    }

    /// Linear percentage-to-alpha mapping used by the main window chrome.
    var chromeAlpha: CGFloat { CGFloat(windowTransparency / 100.0) }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
        self.appearance = stored.flatMap(Appearance.init(rawValue:)) ?? .system
        if UserDefaults.standard.object(forKey: Self.windowTransparencyDefaultsKey) == nil {
            self.windowTransparency = 100
        } else {
            self.windowTransparency = min(
                max(UserDefaults.standard.double(forKey: Self.windowTransparencyDefaultsKey), 1),
                100
            )
        }
        if UserDefaults.standard.object(forKey: Self.showReadingProgressDefaultsKey) == nil {
            self.showReadingProgress = true
        } else {
            self.showReadingProgress = UserDefaults.standard.bool(forKey: Self.showReadingProgressDefaultsKey)
        }
        if UserDefaults.standard.object(forKey: Self.aiPanelWidthDefaultsKey) == nil {
            self.aiPanelWidth = 340
        } else {
            self.aiPanelWidth = min(
                max(UserDefaults.standard.double(forKey: Self.aiPanelWidthDefaultsKey), 280),
                620
            )
        }
        self.chatFontName = UserDefaults.standard.string(forKey: Self.chatFontNameDefaultsKey) ?? "System"
        if UserDefaults.standard.object(forKey: Self.chatFontSizeDefaultsKey) == nil {
            self.chatFontSize = 13
        } else {
            self.chatFontSize = min(
                max(UserDefaults.standard.double(forKey: Self.chatFontSizeDefaultsKey), 10),
                28
            )
        }
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
