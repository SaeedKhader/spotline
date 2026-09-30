import EditorCommands
import SpotlineAccessibility
import SwiftUI
import SubtitleTranslation

/// The glossary of the language pair being translated: one editable row per
/// term (source, translation, note). Terms are checked against every cue as
/// they change. Import a CSV or tab-separated file from Translation › Import Glossary.
struct GlossaryView: View {
    let editor: EditorState
    @State private var selection = Set<UUID>()
    @FocusState private var focusedEntry: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(pairTitle).font(.headline)
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
                Table(editor.glossary.entries, selection: $selection) {
                    TableColumn("Source") { entry in field(entry, .source).focused($focusedEntry, equals: entry.id) }
                    TableColumn("Translation") { entry in field(entry, .target) }
                    TableColumn("Note") { entry in field(entry, .note) }
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
        return TextField(field == .source ? "Term" : field == .target ? "Translation" : "Note", text: Binding(
            get: {
                let current = editor.glossary.entries.first { $0.id == entry.id } ?? entry
                return switch field {
                case .source: current.source
                case .target: current.target
                case .note: current.note
                }
            },
            set: { value in
                guard var current = editor.glossary.entries.first(where: { $0.id == entry.id }) else { return }
                switch field {
                case .source: current.source = value
                case .target: current.target = value
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
