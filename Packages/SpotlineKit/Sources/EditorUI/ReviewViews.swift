import AITools
import EditorCommands
import SpotlineAccessibility
import SubtitleCore
import SubtitleTranslation
import SwiftUI

/// An AI tool's proposed change to one cue, under its text: the new text as a
/// word diff (removed words struck out in red, new ones in green), changed
/// timing, speaker and addressee, and buttons to accept or reject it.
struct ProposalBox: View {
    let editor: EditorState
    let change: ProposedChange
    let direction: TextDirection

    var body: some View {
        let before = change.before
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                if case .delete = change.kind {
                    Text("Remove this cue")
                        .foregroundStyle(.red)
                } else if let before, before.text != change.cue.text {
                    DiffText(old: before.text, new: change.cue.text)
                        .environment(\.layoutDirection, direction.layoutDirection)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                details
                if let note = change.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ReviewButtons(editor: editor, cueID: change.cueID)
        }
        .font(.callout)
        .padding(8)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor.opacity(0.35)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Proposed change")
        .accessibilityValue(change.cue.text)
        .accessibilityIdentifier(AccessibilityID.CueList.cell(change.cueID, .proposal))
    }

    /// Timing, speaker and addressee changes, as "before → after".
    @ViewBuilder private var details: some View {
        if let before = change.before, change.kind != .delete {
            let parts = [
                before.start != change.cue.start || before.end != change.cue.end
                    ? "\(editor.label(for: change.cue.start)) – \(editor.label(for: change.cue.end))" : nil,
                before.speakerID != change.cue.speakerID ? change.cue.speakerID.flatMap { speakerText($0) }.map { "Speaker \($0)" } : nil,
                before.addressee != change.cue.addressee ? change.cue.addressee.map(addresseeText) : nil,
                change.cue.variants != nil && before.variants == nil ? "\(change.cue.variants!.count) variants" : nil,
            ].compactMap { $0 }
            if !parts.isEmpty {
                Text(parts.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func speakerText(_ id: Speaker.ID) -> String? {
        editor.speakerLabel(id) ?? editor.pendingReview?.newSpeakers.firstIndex { $0.id == id }.map {
            EditorState.speakerLetter(editor.track.speakers.count + $0)
        }
    }

    private func addresseeText(_ tag: AddresseeTag) -> String {
        "Spoken to \(tag.addressee.symbol) \(tag.addressee.displayName), \(Int((tag.confidence * 100).rounded()))% sure"
    }
}

/// Words of `old` that go struck out in red, words of `new` that come in green.
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
                piece.foregroundColor = .green
                piece.backgroundColor = Color.green.opacity(0.12)
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

/// A cue a tool proposes to add (transcription), shown in its place among the
/// real cues until it is accepted or rejected.
struct ProposedCueRow: View {
    let editor: EditorState
    let change: ProposedChange
    let direction: TextDirection

    var body: some View {
        let cue = change.cue
        let isSelected = editor.selectedCueID == cue.id
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "plus")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)
                .frame(width: 32, alignment: .trailing)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(editor.label(for: cue.start))
                Text(editor.label(for: cue.end))
            }
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .frame(width: 130, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(cue.text)
                    .font(.system(size: 15))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection, direction.layoutDirection)
                    .accessibilityLabel("Proposed text")
                    .accessibilityValue(cue.text)
                    .accessibilityIdentifier(AccessibilityID.CueList.proposedCell(cue.id, .text))
                if let id = cue.speakerID, let label = speakerLabel(id) {
                    Text("Speaker \(label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccessibilityID.CueList.proposedCell(cue.id, .speaker))
                }
            }
            ReviewButtons(editor: editor, cueID: cue.id)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.green.opacity(0.05))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.CueList.proposedRow(cue.id))
    }

    private func speakerLabel(_ id: Speaker.ID) -> String? {
        guard let review = editor.pendingReview, let index = review.newSpeakers.firstIndex(where: { $0.id == id }) else {
            return editor.speakerLabel(id)
        }
        let speaker = review.newSpeakers[index]
        let letter = EditorState.speakerLetter(editor.track.speakers.count + index)
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

/// The running AI tool with its progress and a cancel button, then the review
/// waiting for a decision with Accept All and Reject All. In the actions bar.
struct AIStatusView: View {
    let editor: EditorState

    var body: some View {
        if let task = editor.aiTask {
            let text = "\(task.title) \(Int((task.fraction * 100).rounded()))%"
            HStack(spacing: 6) {
                ProgressView(value: task.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 70)
                Text(text)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("AI task")
                    .accessibilityValue(text)
                    .accessibilityIdentifier(AccessibilityID.Transport.aiTask)
                CommandButton(command: .cancelAITask, systemImage: "xmark.circle", editor: editor)
            }
        } else if let review = editor.pendingReview {
            let count = review.changes.count
            let text = "\(review.title): \(count == 1 ? "1 change" : "\(count) changes")"
            HStack(spacing: 8) {
                Label(text, systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Review")
                    .accessibilityValue(text)
                    .accessibilityIdentifier(AccessibilityID.Transport.review)
                CommandButton(command: .acceptAllChanges, systemImage: "checkmark.circle", editor: editor)
                CommandButton(command: .rejectAllChanges, systemImage: "xmark.circle", editor: editor)
            }
        }
    }
}
