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
                Toggle("Sound descriptions, for hearing-impaired subtitles", isOn: $editor.aiSettings.includesSoundDescriptions)
                    .help("“(door opens)”, “(laughs)”: kept in transcriptions and translated when on; left out of both when off")
                    .accessibilityIdentifier(AccessibilityID.AISettings.soundDescriptions)
                Picker("Translation", selection: $editor.aiSettings.translation) {
                    ForEach(AISettings.TranslationProvider.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier(AccessibilityID.AISettings.translationProvider)
                if let problem = providerProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityValue(problem)
                        .accessibilityIdentifier(AccessibilityID.AISettings.providerProblem)
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("On this Mac, audio and text never leave your computer. Cleanup always runs here.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Join short lines after translating", isOn: $editor.aiSettings.joinsLinesAfterTranslating)
                    .accessibilityIdentifier(AccessibilityID.AISettings.joinsLines)
                Picker("Wording", selection: $editor.aiSettings.translationStyle.register) {
                    ForEach(TranslationStyle.Register.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier(AccessibilityID.AISettings.register)
                Toggle("No full stop at the end of lines (Arabic, Persian, Urdu)", isOn: $editor.aiSettings.translationStyle.dropsFinalPunctuation)
                    .accessibilityIdentifier(AccessibilityID.AISettings.dropsFinalPunctuation)
                Toggle("Names in parentheses", isOn: $editor.aiSettings.translationStyle.namesInParentheses)
                    .accessibilityIdentifier(AccessibilityID.AISettings.namesInParentheses)
            } header: {
                Text("Translation style")
            } footer: {
                Text("Claude also gets the episode's title from the video's file name, and any notes for the translator from the glossary panel.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Allow cloud providers", isOn: $editor.aiSettings.allowsCloud)
                    .accessibilityIdentifier(AccessibilityID.AISettings.allowsCloud)
                Group {
                    keyField("OpenAI API key", text: $openAIKey, provider: .openAI)
                    keyField("Anthropic API key", text: $anthropicKey, provider: .anthropic)
                    keyField("ElevenLabs API key", text: $elevenLabsKey, provider: .elevenLabs)
                }
                .disabled(!editor.aiSettings.allowsCloud)
            } header: {
                Text("Cloud")
            } footer: {
                Text("Cloud providers receive the dialogue audio or the subtitle text; check your contract before sending material under NDA. Keys are saved in your Keychain when you leave the field.")
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

    /// Why a chosen cloud provider can't run yet, if it can't.
    private var providerProblem: String? {
        let settings = editor.aiSettings
        let candidates: [(name: String, key: APIKeyStore.Provider)?] = [
            settings.transcription == .openAIWhisper ? ("OpenAI Whisper", .openAI) : nil,
            settings.transcription == .elevenLabsScribe ? ("ElevenLabs Scribe", .elevenLabs) : nil,
            settings.translation.apiKeyProvider.map { (settings.translation.providerName, $0) },
        ]
        let needed = candidates.compactMap { $0 }
        guard let first = needed.first else { return nil }
        if !settings.allowsCloud { return "\(first.name) needs Allow cloud providers turned on." }
        if let missing = needed.first(where: { !savedKeys.contains($0.key) }) {
            return "\(missing.name) needs an API key."
        }
        return nil
    }

    private func keyField(_ title: String, text: Binding<String>, provider: APIKeyStore.Provider) -> some View {
        KeyField(title: title, text: text, isSaved: savedKeys.contains(provider), provider: provider) {
            save(text.wrappedValue, for: provider)
        }
    }

    private func save(_ key: String, for provider: APIKeyStore.Provider) {
        guard key != (keys.key(for: provider) ?? "") else { return }
        keys.setKey(key, for: provider)
        if keys.key(for: provider) != nil { savedKeys.insert(provider) } else { savedKeys.remove(provider) }
    }
}

/// An API key field that saves when you press Return or leave it, with a check once the Keychain has it.
private struct KeyField: View {
    let title: String
    @Binding var text: String
    let isSaved: Bool
    let provider: APIKeyStore.Provider
    let save: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            SecureField(title, text: $text)
                .focused($isFocused)
                .onSubmit(save)
                .onChange(of: isFocused) { _, focused in if !focused { save() } }
                .accessibilityIdentifier(AccessibilityID.AISettings.apiKey(provider.rawValue))
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .opacity(isSaved ? 1 : 0)
                .help("Saved in your Keychain")
                .accessibilityLabel("Saved")
                .accessibilityValue(isSaved ? "saved" : "not saved")
                .accessibilityIdentifier(AccessibilityID.AISettings.apiKeySaved(provider.rawValue))
        }
    }
}
