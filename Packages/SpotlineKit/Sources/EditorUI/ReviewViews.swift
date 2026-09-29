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
                            .foregroundStyle(.tint)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.system(size: 15))
                .environment(\.layoutDirection, direction.layoutDirection)
                .frame(maxWidth: .infinity, alignment: .leading)
                ReviewButtons(editor: editor, cueID: change.cueID)
            }
            ProposalDetails(editor: editor, change: change)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 58, alignment: .top)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor.opacity(0.5)))
        .help("Proposed by \(editor.pendingReview?.title ?? "an AI tool"): accept or reject")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Proposed text")
        .accessibilityValue(change.cue.text)
        .accessibilityIdentifier(AccessibilityID.CueList.cell(change.cueID, .proposal))
    }
}

/// A proposed change that leaves the text alone (a speaker or addressee), or
/// removes the cue: a line under the text with ✓ and ✗.
struct ProposalBox: View {
    let editor: EditorState
    let change: ProposedChange

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
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
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Proposed change")
        .accessibilityValue(change.cue.text)
        .accessibilityIdentifier(AccessibilityID.CueList.cell(change.cueID, .proposal))
    }
}

/// What else a change does, as one caption: timing, speaker, addressee, variants, and the tool's note.
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
            before.speakerID != change.cue.speakerID ? change.cue.speakerID.flatMap { editor.proposedSpeakerLabel($0) }.map { "Speaker \($0)" } : nil,
            before.addressee != change.cue.addressee ? change.cue.addressee.map(addresseeText) : nil,
            (change.cue.variants?.count ?? 0) > 1 && before.variants == nil ? "\(change.cue.variants!.count) variants" : nil,
        ].compactMap { $0 }
    }

    private func addresseeText(_ tag: AddresseeTag) -> String {
        "Spoken to \(tag.addressee.symbol) \(tag.addressee.displayName), \(Int((tag.confidence * 100).rounded()))% sure"
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
                piece.foregroundColor = .accentColor
                piece.backgroundColor = Color.accentColor.opacity(0.15)
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
/// it: its place, start and end, speaker and text, marked as proposed until
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
                .foregroundStyle(.tint)
                .frame(width: 32, alignment: .trailing)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 6) {
                time("S", cue.start)
                time("E", cue.end)
                if let id = cue.speakerID, let label = editor.proposedSpeakerLabel(id) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .padding(.leading, 4)
                        .accessibilityIdentifier(AccessibilityID.CueList.proposedCell(cue.id, .speaker))
                }
            }
            HStack(alignment: .top, spacing: 6) {
                Text(cue.text)
                    .font(.system(size: 15))
                    .foregroundStyle(.tint)
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
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.CueList.proposedRow(cue.id))
    }

    /// A start or end in the same box as a real cue's time field, not editable.
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
        .background(.background.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator.opacity(0.5)))
    }
}

extension EditorState {
    /// A speaker's letter and voice ("C ♀"), also for speakers a pending review would add.
    func proposedSpeakerLabel(_ id: Speaker.ID) -> String? {
        if let label = speakerLabel(id), let speaker = track.speakers.first(where: { $0.id == id }) {
            return speaker.gender == .unknown ? label : "\(label) \(speaker.gender.symbol)"
        }
        guard let review = pendingReview, let index = review.newSpeakers.firstIndex(where: { $0.id == id }) else { return nil }
        let speaker = review.newSpeakers[index]
        let letter = Self.speakerLetter(track.speakers.count + index)
        return speaker.gender == .unknown ? letter : "\(letter) \(speaker.gender.symbol)"
    }
}

/// Who a line is spoken to: ♂, ♀ or a group sign, orange when the tool was
/// unsure. Click it to pick the right addressee: the line switches to the
/// translator's wording for them (one click, undoable), and the tag is confirmed.
struct AddresseeChip: View {
    let editor: EditorState
    let cue: Cue
    let tag: AddresseeTag

    var body: some View {
        Menu {
            let variants = cue.variants ?? []
            let choices = variants.isEmpty ? Addressee.allCases.filter { $0 != .unknown } : variants.map(\.addressee)
            ForEach(choices, id: \.self) { addressee in
                Button {
                    editor.chooseAddressee(addressee, forCue: cue.id)
                } label: {
                    let text = variants.first { $0.addressee == addressee }.map { " — \(SubtitleText.visibleLines(of: $0.text).joined(separator: " / "))" } ?? ""
                    Text("\(addressee.symbol)  \(addressee.displayName)\(text)")
                }
                .accessibilityIdentifier(AccessibilityID.CueList.addresseeChoice(cue.id, addressee.rawValue))
            }
        } label: {
            Text(tag.addressee.symbol)
                .font(.caption)
                .foregroundStyle(tag.needsReview ? Color.orange : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Spoken to: \(tag.addressee.displayName), \(tag.source == .confirmed ? "confirmed" : "\(Int((tag.confidence * 100).rounded()))% sure"). Click to change.")
        .accessibilityLabel("Addressee")
        .accessibilityValue(tag.addressee.rawValue)
        .accessibilityIdentifier(AccessibilityID.CueList.cell(cue.id, .addressee))
    }
}

/// The speaker's letter and voice gender ("A ♀"), found by speaker detection.
struct SpeakerChip: View {
    let editor: EditorState
    let speakerID: Speaker.ID
    let cueID: Cue.ID

    var body: some View {
        if let label = editor.speakerLabel(speakerID), let speaker = editor.track.speakers.first(where: { $0.id == speakerID }) {
            let text = speaker.gender == .unknown ? label : "\(label) \(speaker.gender.symbol)"
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                .help("Speaker \(label): \(speaker.gender.rawValue) voice, \(Int((speaker.confidence * 100).rounded()))% sure")
                .accessibilityLabel("Speaker")
                .accessibilityValue(text)
                .accessibilityIdentifier(AccessibilityID.CueList.cell(cueID, .speaker))
        }
    }
}

extension Addressee {
    var displayName: String {
        switch self {
        case .male: "a man"
        case .female: "a woman"
        case .dualMale: "two men"
        case .dualFemale: "two women"
        case .groupMale: "men"
        case .groupFemale: "women"
        case .groupMixed: "a group"
        case .unknown: "unknown"
        }
    }
}

extension Gender {
    var symbol: String {
        switch self {
        case .male: "♂"
        case .female: "♀"
        case .unknown: "?"
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
                        .foregroundStyle(.tint)
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
                    }
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.08))
                Divider()
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.CueList.aiBar)
        }
    }
}
