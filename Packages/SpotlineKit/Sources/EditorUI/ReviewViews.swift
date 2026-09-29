import AITools
import EditorCommands
import SpotlineAccessibility
import SubtitleCore
import SubtitleTranslation
import SwiftUI

/// The text an AI tool proposes for a cue, in place of the cue's text editor
/// until it is accepted or rejected: the new text in the tint colour, as a word
/// diff when the cue had text (removed words struck out in red), with ✓ and ✗.
struct ProposedText: View {
    let editor: EditorState
    let change: ProposedChange
    let direction: TextDirection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Group {
                    if let before = change.before, !before.text.isEmpty {
                        DiffText(old: before.text, new: change.cue.text)
                    } else {
                        Text(change.cue.text)
                            .foregroundStyle(Color.aiTint)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(SpotlineStyle.cueFont)
                .environment(\.layoutDirection, direction.layoutDirection)
                .frame(maxWidth: .infinity, alignment: .leading)
                ReviewButtons(editor: editor, cueID: change.cueID)
            }
            ProposalDetails(editor: editor, change: change)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 58, alignment: .top)
        .background(Color.aiTint.opacity(0.1), in: RoundedRectangle(cornerRadius: SpotlineStyle.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: SpotlineStyle.cornerRadius).strokeBorder(Color.aiTint.opacity(0.5)))
        .help("Proposed by \(editor.pendingReview?.title ?? "an AI tool"): accept or reject")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Proposed text")
        .accessibilityValue(change.cue.text)
        .accessibilityIdentifier(AccessibilityID.CueList.cell(change.cueID, .proposal))
    }
}

/// A proposed change that leaves the text alone (timing), or removes the cue:
/// a line under the text with ✓ and ✗.
struct ProposalBox: View {
    let editor: EditorState
    let change: ProposedChange

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.aiTint)
            if case .delete = change.kind {
                Text("Remove this cue")
                    .foregroundStyle(.red)
            }
            ProposalDetails(editor: editor, change: change)
            Spacer(minLength: 0)
            ReviewButtons(editor: editor, cueID: change.cueID)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.aiTint.opacity(0.1), in: RoundedRectangle(cornerRadius: SpotlineStyle.cornerRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Proposed change")
        .accessibilityValue(change.cue.text)
        .accessibilityIdentifier(AccessibilityID.CueList.cell(change.cueID, .proposal))
    }
}

/// What else a change does, as one caption: timing, and the tool's note.
struct ProposalDetails: View {
    let editor: EditorState
    let change: ProposedChange

    var body: some View {
        let parts = self.parts
        if !parts.isEmpty || change.note != nil {
            HStack(spacing: 6) {
                if !parts.isEmpty {
                    Text(parts.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                if let note = change.note {
                    Text(note)
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
        }
    }

    private var parts: [String] {
        guard let before = change.before, change.kind != .delete else { return [] }
        return [
            before.start != change.cue.start || before.end != change.cue.end
                ? "\(editor.label(for: change.cue.start)) – \(editor.label(for: change.cue.end))" : nil,
        ].compactMap { $0 }
    }
}

/// Words of `old` that go struck out in red, words of `new` in the tint colour.
struct DiffText: View {
    let old: String
    let new: String

    var body: some View {
        Text(attributed)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for part in TextDiff.words(from: old, to: new) {
            switch part {
            case .same(let text):
                result += AttributedString(text)
            case .removed(let text):
                var piece = AttributedString(text)
                piece.foregroundColor = .red
                piece.strikethroughStyle = .single
                result += piece
            case .added(let text):
                var piece = AttributedString(text)
                piece.foregroundColor = .aiTint
                piece.backgroundColor = Color.aiTint.opacity(0.15)
                result += piece
            }
        }
        return result
    }
}

/// Accept (✓) and reject (✗) for one proposed change.
struct ReviewButtons: View {
    let editor: EditorState
    let cueID: Cue.ID

    var body: some View {
        HStack(spacing: 6) {
            button(.acceptChange, systemImage: "checkmark.circle.fill", tint: .green) { editor.acceptChanges(to: [cueID]) }
            button(.rejectChange, systemImage: "xmark.circle.fill", tint: .secondary) { editor.rejectChanges(to: [cueID]) }
        }
        .font(.title3)
    }

    private func button(_ command: EditorCommand, systemImage: String, tint: some ShapeStyle, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(command.title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .foregroundStyle(tint)
        }
        .buttonStyle(.borderless)
        .help(command.title)
        .accessibilityIdentifier(AccessibilityID.CueList.reviewAction(cueID, command.id))
    }
}

/// A cue a tool proposes to add (transcription), laid out like the cues around
/// it: its place, start and end and text, marked as proposed until
/// it is accepted or rejected.
struct ProposedCueRow: View {
    let editor: EditorState
    let change: ProposedChange
    let direction: TextDirection

    var body: some View {
        let cue = change.cue
        let isSelected = editor.selectedCueID == cue.id
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.callout)
                .foregroundStyle(Color.aiTint)
                .frame(width: 32, alignment: .trailing)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 6) {
                time("S", cue.start)
                time("E", cue.end)
            }
            HStack(alignment: .top, spacing: 6) {
                Text(cue.text)
                    .font(SpotlineStyle.cueFont)
                    .foregroundStyle(Color.aiTint)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection, direction.layoutDirection)
                    .accessibilityLabel("Proposed text")
                    .accessibilityValue(cue.text)
                    .accessibilityIdentifier(AccessibilityID.CueList.proposedCell(cue.id, .text))
                ReviewButtons(editor: editor, cueID: cue.id)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: 58, alignment: .top)
            .background(Color.aiTint.opacity(0.1), in: RoundedRectangle(cornerRadius: SpotlineStyle.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: SpotlineStyle.cornerRadius).strokeBorder(Color.aiTint.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .environment(\.layoutDirection, TextDirections(source: direction, target: direction).rowLayout(isTranslating: editor.isTranslating))
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.CueList.proposedRow(cue.id))
    }

    /// A start or end laid out like a real cue's time field, not editable.
    private func time(_ edge: String, _ time: MediaTime) -> some View {
        HStack(spacing: 0) {
            Text(edge)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Divider().frame(height: 18)
            Text(editor.label(for: time))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .leading)
                .padding(.horizontal, 6)
        }
        .padding(.vertical, 4)
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// A line AI translation could translate more than one way, under its text
/// while the choice is open: why the translator chose what it did and how sure
/// it was, then every variant, the one in use marked. One click uses another.
struct ChoiceBox: View {
    let editor: EditorState
    let cue: Cue
    let flag: TranslationFlag
    let direction: TextDirection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(Color.aiTint)
                Text("\(Int((flag.confidence * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(flag.confidence < 0.75 ? Color.orange : Color.secondary)
                    .help("How sure the translator was of its pick")
                if !flag.note.isEmpty {
                    Text(flag.note)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(flag.note)
                }
            }
            .font(.caption)
            ForEach(Array(flag.variants.enumerated()), id: \.offset) { index, variant in
                VariantOption(editor: editor, cueID: cue.id, index: index, variant: variant, isChosen: index == flag.chosen, direction: direction)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.aiTint.opacity(0.06), in: RoundedRectangle(cornerRadius: SpotlineStyle.cornerRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Translation choice")
        .accessibilityValue(flag.note)
        .accessibilityIdentifier(AccessibilityID.CueList.cell(cue.id, .choices))
    }
}

/// One variant of a flagged line: who it assumes ("Beth ♀ to Morty ♂") and its text.
private struct VariantOption: View {
    let editor: EditorState
    let cueID: Cue.ID
    let index: Int
    let variant: TranslationVariant
    let isChosen: Bool
    let direction: TextDirection

    var body: some View {
        let text = SubtitleText.visibleLines(of: variant.text).joined(separator: " / ")
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isChosen ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isChosen ? Color.aiTint : Color.secondary)
            Text(variant.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 130, alignment: .leading)
            Text(text)
                .lineLimit(2)
                .environment(\.layoutDirection, direction.layoutDirection)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { editor.chooseVariant(index, forCue: cueID) }
        .help(isChosen ? "In use" : "Use this translation")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(variant.summary)
        .accessibilityValue(variant.text)
        .accessibilityIdentifier(AccessibilityID.CueList.variant(cueID, index))
        .accessibilityAction { editor.chooseVariant(index, forCue: cueID) }
    }
}

/// A row hover action for a line whose choice is made: the other variants, to swap one in.
struct VariantsMenu: View {
    let editor: EditorState
    let cue: Cue
    let flag: TranslationFlag

    var body: some View {
        Menu {
            ForEach(Array(flag.variants.enumerated()), id: \.offset) { index, variant in
                Toggle(isOn: Binding(get: { index == flag.chosen }, set: { _ in editor.chooseVariant(index, forCue: cue.id) })) {
                    Text("\(variant.summary) — \(SubtitleText.visibleLines(of: variant.text).joined(separator: " / "))")
                }
            }
        } label: {
            Label("Other Translations", systemImage: "arrow.triangle.branch")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Other translations of this line")
        .accessibilityIdentifier(AccessibilityID.CueList.cell(cue.id, .variantsMenu))
    }
}

/// Over the cue list while it shows only the lines to choose for.
struct ChoiceReviewHeader: View {
    let editor: EditorState

    var body: some View {
        let count = editor.cuesToChoose.count
        let text = "\(count == 1 ? "1 line reads" : "\(count) lines read") more than one way, least sure first. "
            + "Pick a translation, or keep the rest with \(EditorCommand.acceptRemainingChoices.menuHint("AI"))."
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(Color.aiTint)
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.aiTint.opacity(0.08))
            Divider()
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(text)
        .accessibilityIdentifier(AccessibilityID.CueList.choiceReview)
    }
}

extension TranslationVariant {
    /// Who the variant assumes, in a few words: "Beth ♀ to Morty ♂", "to two women".
    var summary: String {
        var speakerPart: String?
        if let speaker { speakerPart = "\(speaker) \(speakerGender.symbol)".trimmingCharacters(in: .whitespaces) }
        else if speakerGender == .male || speakerGender == .female { speakerPart = "\(speakerGender == .male ? "a man" : "a woman") speaking" }
        var listenerPart: String?
        if !listeners.isEmpty {
            listenerPart = "to \(listeners.joined(separator: " & ")) \(listenerGender.symbol)".trimmingCharacters(in: .whitespaces)
        } else if listenerGender != .unknown || listenerCount != .unknown {
            listenerPart = "to \(Self.describe(listenerGender, listenerCount))"
        }
        return [speakerPart, listenerPart].compactMap { $0 }.joined(separator: " ").nonEmpty ?? "Another reading"
    }

    static func describe(_ gender: Gender, _ count: ListenerCount) -> String {
        switch (count, gender) {
        case (.one, .male), (.unknown, .male): "a man"
        case (.one, .female), (.unknown, .female): "a woman"
        case (.two, .male): "two men"
        case (.two, .female): "two women"
        case (.two, _): "two people"
        case (.many, .male): "men"
        case (.many, .female): "women"
        case (.many, _), (.unknown, .mixed), (.one, .mixed): "a group"
        default: "someone"
        }
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}

extension Gender {
    var symbol: String {
        switch self {
        case .male: "♂"
        case .female: "♀"
        case .mixed: "♂♀"
        case .unknown: ""
        }
    }
}

/// Over the cue list while an AI tool is at work: its progress with Cancel,
/// and how many of its changes wait for review, with Accept All and Reject All.
struct AIReviewBar: View {
    let editor: EditorState

    var body: some View {
        if editor.aiTask != nil || editor.pendingReview != nil {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.aiTint)
                    if let review = editor.pendingReview {
                        let count = review.changes.count
                        let text = "\(review.title): \(count == 1 ? "1 change" : "\(count) changes") to review"
                        Text(text)
                            .accessibilityLabel("Review")
                            .accessibilityValue(text)
                            .accessibilityIdentifier(AccessibilityID.CueList.aiReview)
                    }
                    if let task = editor.aiTask {
                        let text = "\(task.title) \(Int((task.fraction * 100).rounded()))%"
                        ProgressView(value: task.fraction)
                            .progressViewStyle(.linear)
                            .tint(Color.aiTint)
                            .frame(width: 80)
                        Text(text)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("AI task")
                            .accessibilityValue(text)
                            .accessibilityIdentifier(AccessibilityID.CueList.aiTask)
                        CommandButton(command: .cancelAITask, systemImage: "stop.circle", editor: editor)
                    }
                    Spacer(minLength: 8)
                    if editor.pendingReview != nil {
                        CommandButton(command: .rejectAllChanges, editor: editor)
                        CommandButton(command: .acceptAllChanges, editor: editor)
                            .buttonStyle(.borderedProminent)
                            .tint(Color.aiTint)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.aiTint.opacity(0.08))
                Divider()
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.CueList.aiBar)
        }
    }
}
