import AITools
import SpotlineAccessibility
import SubtitleCore
import SubtitleTranslation
import SwiftUI

/// The episode brief, to confirm as it is or edit first (AI › Episode Brief…, and
/// by itself once it is built after transcription). One row a person: the voices,
/// their first line to play, name, gender and the target language's spelling, and how
/// sure the brief is. Two voices that are one person merge. Below, the show's names
/// and terms, each ticked to go into the glossary, then the plot and, scene by scene,
/// who talks to whom, as text to edit. The review waits for Confirm.
struct EpisodeBriefSheet: View {
    let editor: EditorState
    @State private var draft: EpisodeBrief?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let draft {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        peopleSection(draft)
                        termsSection(draft)
                        storySection
                    }
                    .padding(.vertical, 2)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(minHeight: 200, maxHeight: 520)
            }
            footer
        }
        .padding(20)
        .frame(width: 720)
        .onAppear { draft = editor.track.brief }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Brief.sheet)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Episode Brief").font(.headline)
                if let work = draft?.work {
                    Text(work).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Text(draft?.isConfirmed == true
                ? "Changes here update who is who for translation. They don't rerun anything."
                : "Check who is who and how names are spelled, then confirm. The review opens after that, and translation uses these names and genders.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Not Now") { editor.dismissEpisodeBrief() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(AccessibilityID.Brief.notNowButton)
            Button("Confirm") {
                if let draft { editor.confirmEpisodeBrief(draft) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(draft == nil)
            .accessibilityIdentifier(AccessibilityID.Brief.confirmButton)
        }
    }

    private var targetName: String { EditorState.languageName(draft?.targetLanguage ?? "und") }

    private var targetIsRightToLeft: Bool {
        TextDirection.of(languageCode: draft?.targetLanguage ?? "und") == .rightToLeft
    }

    // MARK: People

    private func peopleSection(_ brief: EpisodeBrief) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cast").font(.subheadline.weight(.semibold))
            if brief.people.isEmpty {
                Text("Nobody was told apart in the transcript.").foregroundStyle(.secondary)
            }
            ForEach(brief.people) { person in
                PersonRow(
                    editor: editor, person: binding(person.id), others: brief.people.filter { $0.id != person.id },
                    spellingLabel: "\(targetName) spelling", isRightToLeft: targetIsRightToLeft,
                    merge: { into in draft?.merge(person.id, into: into) },
                    remove: { draft?.people.removeAll { $0.id == person.id } }
                )
                Divider()
            }
        }
    }

    private func binding(_ id: EpisodeBrief.Person.ID) -> Binding<EpisodeBrief.Person> {
        Binding(
            get: { draft?.people.first { $0.id == id } ?? EpisodeBrief.Person(id: id) },
            set: { value in
                guard let index = draft?.people.firstIndex(where: { $0.id == id }) else { return }
                draft?.people[index] = value
            }
        )
    }

    // MARK: Terms

    private func termsSection(_ brief: EpisodeBrief) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Names and terms").font(.subheadline.weight(.semibold))
            if brief.terms.isEmpty {
                Text("No places or made-up words were found.").foregroundStyle(.secondary)
            }
            ForEach(brief.terms) { term in
                TermRow(
                    term: termBinding(term.id), translationLabel: targetName, isRightToLeft: targetIsRightToLeft,
                    remove: { draft?.terms.removeAll { $0.id == term.id } }
                )
            }
            Button("Add Term") { draft?.terms.append(EpisodeBrief.Term(term: "", addsToGlossary: true)) }
                .controlSize(.small)
                .accessibilityIdentifier(AccessibilityID.Brief.addTerm)
        }
    }

    // MARK: Plot and scenes

    private var storySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Plot").font(.subheadline.weight(.semibold))
            TextEditor(text: Binding(get: { draft?.plot ?? "" }, set: { draft?.plot = $0 }))
                .font(.body)
                .frame(height: 64)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
                .accessibilityLabel("Plot")
                .accessibilityIdentifier(AccessibilityID.Brief.plot)
            Text("Scenes").font(.subheadline.weight(.semibold))
            Text("Who talks to whom in each scene, one line each. The translator uses this to tell who “you” is.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: Binding(get: { draft?.scenes ?? "" }, set: { draft?.scenes = $0 }))
                .font(.body)
                .frame(height: 140)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
                .accessibilityLabel("Scenes")
                .accessibilityIdentifier(AccessibilityID.Brief.scenes)
        }
    }

    private func termBinding(_ id: EpisodeBrief.Term.ID) -> Binding<EpisodeBrief.Term> {
        Binding(
            get: { draft?.terms.first { $0.id == id } ?? EpisodeBrief.Term(id: id, term: "") },
            set: { value in
                guard let index = draft?.terms.firstIndex(where: { $0.id == id }) else { return }
                draft?.terms[index] = value
            }
        )
    }
}

/// How sure the brief is: "95%", in orange under 80%.
private struct Confidence: View {
    let value: Double

    var body: some View {
        Text("\(Int((value * 100).rounded()))%")
            .font(.caption.monospacedDigit())
            .foregroundStyle(value < 0.8 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .frame(width: 36, alignment: .trailing)
            .help(value < 0.8 ? "The brief is unsure: check this one." : "How sure the brief is")
    }
}

private struct PersonRow: View {
    let editor: EditorState
    @Binding var person: EpisodeBrief.Person
    let others: [EpisodeBrief.Person]
    let spellingLabel: String
    let isRightToLeft: Bool
    let merge: (EpisodeBrief.Person.ID) -> Void
    let remove: () -> Void

    var body: some View {
        let line = editor.firstLine(of: person.voices)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    editor.playFirstLine(of: person.voices)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .disabled(line == nil || !editor.hasMedia)
                .help("Play their first line")
                .accessibilityLabel("Play")
                .accessibilityIdentifier(AccessibilityID.Brief.play(person.id))
                Text(person.voices.isEmpty ? "Doesn't speak" : person.voices.joined(separator: " + "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let line {
                    Text("“\(SubtitleText.visibleLines(of: line.text).joined(separator: " "))”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                Confidence(value: person.confidence)
            }
            HStack(spacing: 8) {
                TextField("Name", text: $person.name)
                    .frame(width: 200)
                    .accessibilityIdentifier(AccessibilityID.Brief.name(person.id))
                Picker("Gender", selection: $person.gender) {
                    Text("Male").tag(Gender.male)
                    Text("Female").tag(Gender.female)
                    Text("Unknown").tag(Gender.unknown)
                }
                .labelsHidden()
                .frame(width: 110)
                .accessibilityIdentifier(AccessibilityID.Brief.gender(person.id))
                TextField(spellingLabel, text: $person.translatedName)
                    .multilineTextAlignment(isRightToLeft ? .trailing : .leading)
                    .frame(width: 200)
                    .accessibilityIdentifier(AccessibilityID.Brief.spelling(person.id))
                Spacer(minLength: 0)
                Menu {
                    if !others.isEmpty {
                        Section("Same person as") {
                            ForEach(others) { other in
                                Button(other.name.isEmpty ? other.voices.joined(separator: " + ") : other.name) { merge(other.id) }
                            }
                        }
                    }
                    Button("Remove", role: .destructive, action: remove)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Merge with another person, or remove")
                .accessibilityLabel("More")
                .accessibilityIdentifier(AccessibilityID.Brief.menu(person.id))
            }
            if !person.note.isEmpty {
                Text(person.note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue("\(person.voices.joined(separator: ", ")), \(Int((person.confidence * 100).rounded()))%")
        .accessibilityIdentifier(AccessibilityID.Brief.person(person.id))
    }
}

private struct TermRow: View {
    @Binding var term: EpisodeBrief.Term
    let translationLabel: String
    let isRightToLeft: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Add to glossary", isOn: $term.addsToGlossary)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Add to the glossary on Confirm")
                .accessibilityIdentifier(AccessibilityID.Brief.termGlossary(term.id))
            TextField("Term", text: $term.term)
                .frame(width: 170)
                .help(term.heardAs.isEmpty ? "" : "Heard as \(term.heardAs.joined(separator: ", "))")
                .accessibilityIdentifier(AccessibilityID.Brief.termText(term.id))
            TextField(translationLabel, text: $term.translation)
                .multilineTextAlignment(isRightToLeft ? .trailing : .leading)
                .frame(width: 150)
                .accessibilityIdentifier(AccessibilityID.Brief.termTranslation(term.id))
            TextField("Note", text: $term.note)
                .accessibilityIdentifier(AccessibilityID.Brief.termNote(term.id))
            Confidence(value: term.confidence)
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove")
            .accessibilityLabel("Remove")
            .accessibilityIdentifier(AccessibilityID.Brief.removeTerm(term.id))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Brief.term(term.id))
    }
}
