import SwiftUI
import PaperReaderCore

/// Preferences screen (spec §5), opened via **⌘,** / App menu → "Preferences…"
/// (wired up as the app's `Settings` scene in `PaperReaderApp`, which macOS
/// binds to that menu item automatically).
///
/// Two sections:
/// - **API Key** — the Anthropic API key, stored in the Keychain only — never
///   in UserDefaults or plaintext on disk — via `KeychainService`.
/// - **Appearance** — System/Light/Dark, persisted in UserDefaults (a
///   non-secret UI preference) and applied live via `AppearanceManager`.
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
        }
        .frame(width: 460, height: 260)
    }
}

private struct APIKeySettingsView: View {
    private let keychain = KeychainService()

    @State private var keyInput: String = ""
    @State private var hasStoredKey: Bool = false
    @State private var didJustSave: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Anthropic API Key")
                .font(.headline)

            if hasStoredKey {
                Label("A key is currently set", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }

            SecureField("sk-ant-…", text: $keyInput)
                .textFieldStyle(.roundedBorder)

            Text("Stored securely in the macOS Keychain. Required to use the Claude panel in the reader.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Save") {
                    save()
                }
                .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Remove Key", role: .destructive) {
                    remove()
                }
                .disabled(!hasStoredKey)

                Spacer()

                if didJustSave {
                    Label("Saved", systemImage: "checkmark")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }

            Spacer()
        }
        .padding(20)
        .onAppear {
            hasStoredKey = keychain.hasAPIKey
        }
    }

    private func save() {
        let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? keychain.setAPIKey(trimmed)
        keyInput = ""
        hasStoredKey = keychain.hasAPIKey
        didJustSave = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didJustSave = false
        }
    }

    private func remove() {
        keychain.deleteAPIKey()
        hasStoredKey = keychain.hasAPIKey
        keyInput = ""
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

            Text("Changes apply immediately across all windows.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(20)
    }
}
