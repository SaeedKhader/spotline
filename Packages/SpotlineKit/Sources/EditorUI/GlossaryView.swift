import EditorCommands
import SpotlineAccessibility
import SwiftUI
import SubtitleTranslation

/// The glossary of the language pair being translated: one editable row per
/// term (source, translation, note), ticked "This show" when it belongs to the show
/// being translated rather than to every show. Terms are checked against every cue as
/// they change. Import a CSV or tab-separated file from Translation › Import Glossary.
struct GlossaryView: View {
    let editor: EditorState
    @State private var selection = Set<UUID>()
    @FocusState private var focusedEntry: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(pairTitle).font(.headline)
                if let show = editor.glossaryShow {
                    Text(show).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(editor.glossary.entries.count == 1 ? "1 term" : "\(editor.glossary.entries.count) terms")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if editor.glossary.entries.isEmpty {
                ContentUnavailableView(
                    "No Terms",
                    systemImage: "character.book.closed",
                    description: Text("Add names and terms with their agreed translations. Cues whose source uses a term show it, and Review flags translations that don't use it.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let disagreements = editor.glossary.disagreements
                Table(editor.glossary.entries, selection: $selection) {
                    TableColumn("Source") { entry in
                        HStack(spacing: 4) {
                            field(entry, .source).focused($focusedEntry, equals: entry.id)
                            if let other = disagreements[entry.id] {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help("Another entry translates this term as “\(other)”. Keep one.")
                                    .accessibilityIdentifier(AccessibilityID.Glossary.disagrees(entry.id))
                            }
                        }
                    }
                    TableColumn("Translation") { entry in field(entry, .target) }
                    TableColumn("Also accepted") { entry in
                        AlternativesField(editor: editor, entryID: entry.id)
                            .environment(\.layoutDirection, editor.targetDirection == .rightToLeft ? .rightToLeft : .leftToRight)
                    }
                    TableColumn("Note") { entry in field(entry, .note) }
                    TableColumn("This show") { entry in
                        Toggle("This show", isOn: Binding(
                            get: { editor.glossary.entries.first { $0.id == entry.id }?.show != nil },
                            set: { editor.setGlossaryEntry(entry.id, isForThisShow: $0) }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .disabled(editor.glossaryShow == nil)
                        .help(editor.glossaryShow.map { "Ticked: only for \($0). Unticked: for every show." } ?? "Open a video named after its show to keep terms for that show")
                        .accessibilityIdentifier(AccessibilityID.Glossary.isForShow(entry.id))
                    }
                    .width(70)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes for the AI translator").font(.caption).foregroundStyle(.secondary)
                TextField(
                    "The show, the setting, who is who: “Dunk is a tall hedge knight; Egg is his squire, a boy.”",
                    text: Binding(get: { editor.track.translatorNotes ?? "" }, set: { editor.setTranslatorNotes($0) }),
                    axis: .vertical
                )
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(AccessibilityID.Glossary.translatorNotes)
            }
            .padding(8)
            Divider()
            HStack(spacing: 8) {
                Button {
                    let id = editor.addGlossaryEntry()
                    selection = [id]
                    Task { @MainActor in focusedEntry = id }
                } label: {
                    Label("Add Term", systemImage: "plus").labelStyle(.iconOnly)
                }
                .help("Add Term")
                .accessibilityIdentifier(AccessibilityID.Glossary.addEntry)
                Button {
                    editor.removeGlossaryEntries(selection)
                    selection = []
                } label: {
                    Label("Remove Terms", systemImage: "minus").labelStyle(.iconOnly)
                }
                .help("Remove Selected Terms")
                .disabled(selection.isEmpty)
                .accessibilityIdentifier(AccessibilityID.Glossary.removeEntries)
                Spacer()
                if let show = editor.glossaryShow, editor.glossary.entries.contains(where: { $0.show == nil }) {
                    Button("Move All to This Show") { editor.moveGeneralGlossaryToShow() }
                        .help("Makes every term for all shows a term of \(show) only")
                        .accessibilityIdentifier(AccessibilityID.Glossary.moveToShow)
                }
                CommandButton(command: .addNamesToGlossary, editor: editor)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .frame(minWidth: 420, minHeight: 240)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Glossary.root)
    }

    private var pairTitle: String {
        let source = EditorState.languageName(editor.sourceTrack?.languageCode ?? "und")
        let target = EditorState.languageName(editor.track.languageCode)
        return "\(source) → \(target)"
    }

    private func field(_ entry: Glossary.Entry, _ field: AccessibilityID.Glossary.Field) -> some View {
        let isTarget = field == .target
        let prompt = switch field {
        case .source: "Term"
        case .target: "Translation"
        case .alternatives: "Others, separated by commas"
        case .note: "Note"
        }
        return TextField(prompt, text: Binding(
            get: {
                let current = editor.glossary.entries.first { $0.id == entry.id } ?? entry
                return switch field {
                case .source: current.source
                case .target: current.target
                case .alternatives: current.alternatives.joined(separator: "، ")
                case .note: current.note
                }
            },
            set: { value in
                guard var current = editor.glossary.entries.first(where: { $0.id == entry.id }) else { return }
                switch field {
                case .source: current.source = value
                case .target: current.target = value
                case .alternatives: current.alternatives = AlternativesField.parse(value)
                case .note: current.note = value
                }
                editor.updateGlossaryEntry(current)
            }
        ))
        .textFieldStyle(.plain)
        .environment(\.layoutDirection, isTarget && editor.targetDirection == .rightToLeft ? .rightToLeft : .leftToRight)
        .accessibilityIdentifier(AccessibilityID.Glossary.field(entry.id, field))
    }
}

/// A term's other accepted translations, separated by commas: kept as typed while editing,
/// and read into the glossary on Return or when the field is left.
private struct AlternativesField: View {
    let editor: EditorState
    let entryID: UUID
    @State private var draft: String?
    @FocusState private var isFocused: Bool

    private var stored: String {
        editor.glossary.entries.first { $0.id == entryID }?.alternatives.joined(separator: "، ") ?? ""
    }

    var body: some View {
        TextField("Others, separated by commas", text: Binding(get: { draft ?? stored }, set: { draft = $0 }))
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) { _, focused in if !focused { commit() } }
            .accessibilityIdentifier(AccessibilityID.Glossary.field(entryID, .alternatives))
    }

    private func commit() {
        guard let draft, var entry = editor.glossary.entries.first(where: { $0.id == entryID }) else { return }
        entry.alternatives = Self.parse(draft)
        editor.updateGlossaryEntry(entry)
        self.draft = nil
    }

    static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "،" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
