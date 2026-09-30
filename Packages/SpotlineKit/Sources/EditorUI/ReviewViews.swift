import AITools
import EditorCommands
import SpotlineAccessibility
import SubtitleCore
import SubtitleTranslation
import SwiftUI

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

/// A cue a tool proposes to add, laid out like the cues around it: its place,
/// start and end and text, marked as proposed until it is accepted or rejected
/// in the review sidebar.
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

/// A running AI tool: "Transcription · Step 4 of 4: ElevenLabs Scribe is
/// transcribing · 0:09 of about 1:20" over a bar with a segment per step.
struct AITaskProgress: View {
    let task: AITaskStatus

    var body: some View {
        // Waited time and time left move on their own; everything else changes with the task.
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
                StageBar(stages: task.stages.count, stage: task.stage, fraction: task.fraction(at: context.date))
            }
            .help(task.stages.enumerated().map { ($0.offset == task.stage ? "▸ " : "   ") + $0.element }.joined(separator: "\n"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("AI task")
            .accessibilityValue("\(task.title): \(text)")
            .accessibilityIdentifier(AccessibilityID.CueList.aiTask)
        }
    }

    /// "Step 4 of 5: ElevenLabs Scribe is transcribing · 0:09 of about 1:20", "Claude · 120 of 640 lines · about 4 min left".
    private func details(now: Date) -> String {
        var parts = [task.step.map { "\($0): \(task.detail)" } ?? task.detail]
        if let waited = task.waited(at: now) { parts.append(waited) }
        if let end = task.estimatedEnd, let left = AITaskStatus.timeLeft(until: end, now: now) { parts.append(left) }
        return parts.joined(separator: " · ")
    }
}

/// A bar with a segment per step: steps done are full, later ones empty, and the
/// current one fills as far as it is measured (or as long as it usually takes).
/// When nothing measures it, a shimmer runs through it left to right.
private struct StageBar: View {
    let stages: Int
    let stage: Int
    let fraction: Double?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(stages, 1), id: \.self) { index in
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(index < stage ? Color.aiTint : index == stage ? Color.aiTint.opacity(0.2) : Color.secondary.opacity(0.25))
                        if index == stage {
                            if let fraction {
                                Capsule().fill(Color.aiTint)
                                    .frame(width: max(geometry.size.width * min(max(fraction, 0), 1), 5))
                                    .animation(.easeOut(duration: 0.3), value: fraction)
                            } else {
                                StageShimmer()
                            }
                        }
                    }
                }
                .frame(height: 5)
            }
        }
    }
}

/// A band of the AI tint sweeping left to right, over and over; still with Reduce Motion.
/// Driven by the clock, not a repeating animation: a `repeatForever` started in
/// `onAppear` also repeats every layout change made with it, which in the title
/// bar sent the whole activity sliding back and forth.
private struct StageShimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SwiftUI.TimelineView(.animation(paused: reduceMotion)) { context in
            let phase = reduceMotion ? 0.5 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
            GeometryReader { geometry in
                let band = max(geometry.size.width * 0.45, 12)
                LinearGradient(colors: [Color.aiTint.opacity(0), Color.aiTint, Color.aiTint.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: band)
                    .offset(x: -band + (geometry.size.width + band) * phase)
            }
        }
        .clipShape(Capsule())
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
