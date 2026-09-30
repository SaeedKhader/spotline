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
                    .foregroundStyle(Color.errorTint)
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
                        .foregroundStyle(Color.attentionTint)
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

/// Words of `old` that go struck out in red, words of `new` in the AI tint.
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
                piece.foregroundColor = .errorTint
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
            button(.acceptChange, systemImage: "checkmark.circle.fill", tint: Color.accentColor) { editor.acceptChanges(to: [cueID]) }
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
                    .foregroundStyle(flag.confidence < 0.75 ? Color.attentionTint : Color.secondary)
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

extension TranslationVariant {
    /// Who the variant assumes, in a few words: "Beth ♀ to Morty ♂", "to two women".
    var summary: String {
        if let assumedSource { return "If the line is “\(assumedSource.replacing("\n", with: " "))”" }
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

/// A running AI tool: "Transcription · ElevenLabs Scribe is transcribing · 1:12"
/// over a bar with a segment per stage.
struct AITaskProgress: View {
    let task: AITaskStatus

    var body: some View {
        // Elapsed time and time left move on their own; everything else changes with the task.
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
            let text = details(now: context.date)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    Text(task.title).fontWeight(.medium)
                    Text(" · " + text)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .lineLimit(1)
                .truncationMode(.middle)
                StageBar(stages: task.stages.count, stage: task.stage, fraction: task.fraction)
                    .frame(maxWidth: 260)
            }
            .help(task.stages.enumerated().map { ($0.offset == task.stage ? "▸ " : "   ") + $0.element }.joined(separator: "\n"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("AI task")
            .accessibilityValue("\(task.title): \(text)")
            .accessibilityIdentifier(AccessibilityID.CueList.aiTask)
        }
    }

    /// "Claude · 120 of 640 lines · about 4 min left".
    private func details(now: Date) -> String {
        var parts = [task.detail]
        if let since = task.waitingSince { parts.append(AITaskStatus.elapsed(since: since, now: now)) }
        if let end = task.estimatedEnd, let left = AITaskStatus.timeLeft(until: end, now: now) { parts.append(left) }
        return parts.joined(separator: " · ")
    }
}

/// A thin bar with a segment per stage: stages done are full, the current one
/// fills as far as it is measured, or pulses when nothing measures it.
private struct StageBar: View {
    let stages: Int
    let stage: Int
    let fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(stages, 1), id: \.self) { index in
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.aiTint.opacity(0.18))
                        if index < stage {
                            Capsule().fill(Color.aiTint)
                        } else if index == stage {
                            if let fraction {
                                Capsule().fill(Color.aiTint)
                                    .frame(width: max(geometry.size.width * min(max(fraction, 0), 1), 4))
                                    .animation(.easeOut(duration: 0.3), value: fraction)
                            } else {
                                Capsule().fill(Color.aiTint.opacity(pulse ? 0.75 : 0.35))
                            }
                        }
                    }
                }
            }
        }
        .frame(height: 4)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// Over the rows of the lines a translator is working on now: a soft sweep in the AI tint.
struct InFlightShimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Color.aiTint.opacity(0.08)
        } else {
            SwiftUI.TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                GeometryReader { geometry in
                    LinearGradient(colors: [.clear, Color.aiTint.opacity(0.16), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geometry.size.width * 0.5)
                        .offset(x: geometry.size.width * 1.5 * phase - geometry.size.width * 0.5)
                }
            }
            .background(Color.aiTint.opacity(0.04))
            .clipped()
        }
    }
}

/// Under a cue with words the transcriber was unsure of: each word with how
/// sure it was, a button to hear it and one to keep it. Fixing the text in the
/// editor above clears the word too.
struct WordCheckBox: View {
    let editor: EditorState
    let cue: Cue
    let words: [UnsureWord]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "ear").foregroundStyle(Color.attentionTint)
                Text(words.count == 1 ? "The transcription wasn't sure of this word" : "The transcription wasn't sure of these words")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                WordToCheck(editor: editor, cueID: cue.id, index: index, word: word)
            }
            Text("Listen, then click the word to fix it in the text above, or confirm it.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.attentionTint.opacity(0.07), in: RoundedRectangle(cornerRadius: SpotlineStyle.cornerRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Words to check")
        .accessibilityIdentifier(AccessibilityID.CueList.cell(cue.id, .words))
    }
}

/// One word to check: the word, how sure the transcriber was, Play and Confirm.
private struct WordToCheck: View {
    let editor: EditorState
    let cueID: Cue.ID
    let index: Int
    let word: UnsureWord

    var body: some View {
        let percent = word.confidence.map { "\(Int(($0 * 100).rounded()))%" }
        HStack(spacing: 8) {
            Button {
                editor.selectUnsureWord(index, forCue: cueID)
            } label: {
                Text("“\(word.text)”")
                    .underline(color: Color.attentionTint)
                    .font(.callout)
            }
            .help("Select the word in the text to type over it")
            .accessibilityIdentifier(AccessibilityID.CueList.selectWord(cueID, index))
            if let percent {
                Text(percent)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("How sure the transcription was")
            }
            Spacer(minLength: 8)
            Button {
                editor.playUnsureWord(index, forCue: cueID)
            } label: {
                Label("Play", systemImage: "play.circle")
            }
            .disabled(word.start == nil || !editor.hasMedia)
            .help("Hear the word")
            .accessibilityIdentifier(AccessibilityID.CueList.playWord(cueID, index))
            Button {
                editor.confirmUnsureWord(index, forCue: cueID)
            } label: {
                Label("Confirm", systemImage: "checkmark.circle")
            }
            .help("The word is right")
            .accessibilityIdentifier(AccessibilityID.CueList.confirmWord(cueID, index))
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .font(.caption)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(word.text)
        .accessibilityValue(percent.map { "\(word.text), \($0)" } ?? word.text)
        .accessibilityIdentifier(AccessibilityID.CueList.word(cueID, index))
    }
}
