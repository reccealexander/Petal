import SwiftUI
import PaperReaderCore

/// Settings screen for the Anthropic API key (spec §5). The key is stored in
/// the Keychain only — never in UserDefaults or plaintext on disk — via
/// `KeychainService`. Wired up as the app's `Settings` scene in
/// `PaperReaderApp`, so macOS automatically binds it to the standard
/// **⌘,** "Preferences…" menu item.
struct SettingsView: View {
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
        }
        .padding(20)
        .frame(width: 420)
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
