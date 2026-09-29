import AITools
import SpotlineAccessibility
import SwiftUI

/// Settings › AI: which providers the AI tools use, cloud consent and API keys.
public struct AISettingsView: View {
    @Bindable var editor: EditorState
    private let keys: APIKeyStore
    @State private var openAIKey = ""
    @State private var anthropicKey = ""
    @State private var elevenLabsKey = ""
    @State private var savedKeys: Set<APIKeyStore.Provider> = []

    public init(editor: EditorState, keys: APIKeyStore = APIKeyStore()) {
        self.editor = editor
        self.keys = keys
    }

    static let languages = ["en", "ar", "fr", "de", "es", "it", "pt", "nl", "tr", "fa", "he", "ur", "hi", "ru", "el", "zh", "ja", "ko"]

    public var body: some View {
        Form {
            Section {
                Picker("Transcription", selection: $editor.aiSettings.transcription) {
                    ForEach(AISettings.TranscriptionProvider.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier(AccessibilityID.AISettings.transcriptionProvider)
                Picker("Spoken language", selection: $editor.aiSettings.transcriptionLanguage) {
                    Text("From the audio track").tag(String?.none)
                    ForEach(Self.languages, id: \.self) { Text(Languages.name($0)).tag(Optional($0)) }
                }
                .accessibilityIdentifier(AccessibilityID.AISettings.transcriptionLanguage)
                Picker("Translation", selection: $editor.aiSettings.translation) {
                    ForEach(AISettings.TranslationProvider.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier(AccessibilityID.AISettings.translationProvider)
            } header: {
                Text("Providers")
            } footer: {
                Text("On this Mac, audio and text never leave your computer. Speaker and addressee detection and cleanup always run on this Mac. Claude also reads each scene to decide who is spoken to and offers ♂/♀/group variants when unsure.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Allow cloud providers", isOn: $editor.aiSettings.allowsCloud)
                    .accessibilityIdentifier(AccessibilityID.AISettings.allowsCloud)
                keyField("OpenAI API key", text: $openAIKey, provider: .openAI)
                keyField("Anthropic API key", text: $anthropicKey, provider: .anthropic)
                keyField("ElevenLabs API key", text: $elevenLabsKey, provider: .elevenLabs)
            } header: {
                Text("Cloud")
            } footer: {
                Text("Cloud providers receive the dialogue audio (compressed as Opus) or the subtitle text. Check your contract before sending material under NDA. Keys are kept in your Keychain.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear {
            openAIKey = keys.key(for: .openAI) ?? ""
            anthropicKey = keys.key(for: .anthropic) ?? ""
            elevenLabsKey = keys.key(for: .elevenLabs) ?? ""
            savedKeys = Set(APIKeyStore.Provider.allCases.filter { keys.key(for: $0) != nil })
        }
    }

    private func keyField(_ title: String, text: Binding<String>, provider: APIKeyStore.Provider) -> some View {
        HStack {
            SecureField(title, text: text)
                .onSubmit { save(text.wrappedValue, for: provider) }
                .accessibilityIdentifier(AccessibilityID.AISettings.apiKey(provider.rawValue))
            Button("Save") { save(text.wrappedValue, for: provider) }
                .disabled(text.wrappedValue == (keys.key(for: provider) ?? ""))
            if savedKeys.contains(provider) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Saved in your Keychain")
            }
        }
    }

    private func save(_ key: String, for provider: APIKeyStore.Provider) {
        keys.setKey(key, for: provider)
        if keys.key(for: provider) != nil { savedKeys.insert(provider) } else { savedKeys.remove(provider) }
    }
}
