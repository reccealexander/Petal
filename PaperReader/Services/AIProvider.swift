import Foundation

public enum AIProvider: String, CaseIterable, Sendable, Identifiable {
    case claude
    case gemini

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .gemini: "Gemini"
        }
    }
}

/// Persists only the user's provider choice; API keys remain in Keychain.
public enum AIProviderPreference {
    public static let userDefaultsKey = "preferredAIProvider"

    public static func preferred(defaults: UserDefaults = .standard) -> AIProvider {
        guard let rawValue = defaults.string(forKey: userDefaultsKey),
              let provider = AIProvider(rawValue: rawValue) else {
            return .gemini
        }
        return provider
    }

    public static func setPreferred(_ provider: AIProvider, defaults: UserDefaults = .standard) {
        defaults.set(provider.rawValue, forKey: userDefaultsKey)
    }

    /// Honors the preference when possible, otherwise uses the sole available
    /// provider. Returns nil when neither provider has a key.
    public static func effectiveProvider(keychain: KeychainService) -> AIProvider? {
        let preferred = preferred()
        if keychain.hasAPIKey(for: preferred) { return preferred }
        return AIProvider.allCases.first { keychain.hasAPIKey(for: $0) }
    }
}
