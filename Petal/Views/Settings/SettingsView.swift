import SwiftUI
import AppKit
import PetalCore

/// Preferences screen (spec §5), opened via **⌘,** / App menu → "Preferences…"
/// (wired up as the app's `Settings` scene in `PetalApp`, which macOS
/// binds to that menu item automatically).
///
/// Three sections:
/// - **API Keys** — independent Anthropic and Google AI Studio keys stored in
///   Keychain, plus the preferred notebook-summary provider.
/// - **Appearance** — System/Light/Dark, persisted in UserDefaults (a
///   non-secret UI preference) and applied live via `AppearanceManager`.
/// - **Quick Tips** — a plain-language guide to the library's features and
///   keyboard shortcuts.
struct SettingsView: View {
    var body: some View {
        TabView {
            APIKeySettingsView()
                .tabItem {
                    Label("API Key", systemImage: "key.fill")
                }

            AppearanceSettingsView()
                .tabItem {
                    Label("Appearance", systemImage: "circle.righthalf.filled")
                }

            QuickTipsView()
                .tabItem {
                    Label("Quick Tips", systemImage: "questionmark.circle")
                }
        }
        .frame(width: 680, height: 560)
    }
}

private struct APIKeySettingsView: View {
    private let keychain = KeychainService()

    @State private var selectedProvider = AIProviderPreference.preferred()
    @State private var claudeKeyInput = ""
    @State private var geminiKeyInput = ""
    @State private var hasClaudeKey = false
    @State private var hasGeminiKey = false
    @State private var savedProvider: AIProvider?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Notebook Summary Provider").font(.headline)
            Picker("Notebook Summary Provider", selection: $selectedProvider) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(hasClaudeKey != hasGeminiKey)
            .onChange(of: selectedProvider) { _, provider in
                guard providerHasKey(provider) || (!hasClaudeKey && !hasGeminiKey) else {
                    reconcileProviderSelection()
                    return
                }
                AIProviderPreference.setPreferred(provider)
            }

            Text(providerHelp)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            keySection(
                title: "Anthropic (Claude)", provider: .claude,
                placeholder: "sk-ant-…", input: $claudeKeyInput,
                hasKey: hasClaudeKey,
                linkLabel: "Get a key at console.anthropic.com/settings/keys",
                link: "https://console.anthropic.com/settings/keys"
            )
            Divider()
            keySection(
                title: "Google AI Studio (Gemini)", provider: .gemini,
                placeholder: "AIza…", input: $geminiKeyInput,
                hasKey: hasGeminiKey,
                linkLabel: "Get a key at aistudio.google.com/app/apikey",
                link: "https://aistudio.google.com/app/apikey"
            )

            Spacer()
        }
        .padding(20)
        .onAppear { refreshKeyState() }
    }

    private var providerHelp: String {
        if hasClaudeKey != hasGeminiKey {
            return "Notebook summaries use the only provider with a saved key. Add the other key to enable selection."
        }
        return "Choose which provider powers notebook summaries and the reader chat. Both keys can coexist."
    }

    @ViewBuilder
    private func keySection(
        title: String, provider: AIProvider, placeholder: String,
        input: Binding<String>, hasKey: Bool, linkLabel: String, link: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if hasKey {
                Label("A key is currently set", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green).font(.callout)
            }
            SecureField(placeholder, text: input).textFieldStyle(.roundedBorder)
            Text("Stored independently and securely in the macOS Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            Link(linkLabel, destination: URL(string: link)!).font(.caption)
            HStack {
                Button("Save") { save(provider, value: input.wrappedValue) }
                    .disabled(input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Remove Key", role: .destructive) { remove(provider) }
                    .disabled(!hasKey)
                Spacer()
                if savedProvider == provider {
                    Label("Saved", systemImage: "checkmark").foregroundStyle(.green).font(.caption)
                }
            }
        }
    }

    private func save(_ provider: AIProvider, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? keychain.setAPIKey(trimmed, for: provider)
        if provider == .claude { claudeKeyInput = "" } else { geminiKeyInput = "" }
        refreshKeyState()
        savedProvider = provider
        Task {
            try? await Task.sleep(for: .seconds(2))
            if savedProvider == provider { savedProvider = nil }
        }
    }

    private func remove(_ provider: AIProvider) {
        keychain.deleteAPIKey(for: provider)
        if provider == .claude { claudeKeyInput = "" } else { geminiKeyInput = "" }
        refreshKeyState()
    }

    private func refreshKeyState() {
        hasClaudeKey = keychain.hasAPIKey(for: .claude)
        hasGeminiKey = keychain.hasAPIKey(for: .gemini)
        reconcileProviderSelection()
    }

    private func reconcileProviderSelection() {
        if hasClaudeKey != hasGeminiKey {
            selectedProvider = hasClaudeKey ? .claude : .gemini
            AIProviderPreference.setPreferred(selectedProvider)
        } else {
            selectedProvider = AIProviderPreference.preferred()
        }
    }

    private func providerHasKey(_ provider: AIProvider) -> Bool {
        provider == .claude ? hasClaudeKey : hasGeminiKey
    }
}

private struct AppearanceSettingsView: View {
    @EnvironmentObject private var appearance: AppearanceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Appearance")
                .font(.headline)

            Picker("Appearance", selection: $appearance.appearance) {
                ForEach(AppearanceManager.Appearance.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 12) {
                Text("Transparency")
                Slider(value: $appearance.windowTransparency, in: 1...100, step: 1)
                Text("\(Int(appearance.windowTransparency))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }

            Toggle("Show reading-progress indicator", isOn: $appearance.showReadingProgress)

            Text("Shows how far you have read on library cards and rows.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Play launch animation", isOn: $appearance.launchAnimationEnabled)

            Text("When off, “Research Now” opens the library immediately (the opening “Petal.” letters still play).")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Play petal “bloom-to-window” transition", isOn: $appearance.landingTransitionEnabled)
                .disabled(!appearance.launchAnimationEnabled)

            Text("When off, the flower still blooms but the petals-fly-to-the-corners and fill effect is skipped — the library opens right after the bloom.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text("Chat font")
                .font(.headline)

            Picker("Font family", selection: $appearance.chatFontName) {
                Text("System").tag("System")
                ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { family in
                    Text(family).tag(family)
                }
            }

            HStack(spacing: 12) {
                Text("Size")
                Slider(value: $appearance.chatFontSize, in: 10...28, step: 1)
                Text("\(Int(appearance.chatFontSize)) pt")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }

            Text("Appearance changes apply across all windows. Transparency affects only the main library window.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(20)
    }
}
