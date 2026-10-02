import AITools
import EditorCommands
import SpotlineAccessibility
import SubtitleCore
import SwiftUI

/// The plan of Translate with AI (AI › Translate with AI…): every step from the audio
/// to the translated lines, in order. Each can be ticked or left out, steps done
/// already say so (ticking one runs it again), and each has its model and effort
/// and a rough cost. Between the rows, where the run stops for the user. Start runs
/// the ticked steps.
struct AIPlanSheet: View {
    let editor: EditorState
    @State private var ticked: Set<AIFlowStep> = []

    var body: some View {
        let rows = editor.aiPlanRows(ticked: ticked)
        VStack(alignment: .leading, spacing: 12) {
            header
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    Divider()
                    rowView(row)
                    if let stop = stop(after: row.step) {
                        Divider()
                        Label(stop, systemImage: "pause.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.vertical, 6)
                            .padding(.leading, 28)
                    }
                }
                Divider()
            }
            footer
        }
        .padding(20)
        .frame(width: 760)
        .onAppear { ticked = editor.defaultAIPlanTicks }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.AIPlan.sheet)
    }

    /// "Brief", "Translate": a step in a few letters, for the AI bar's list.
    static func shortTitle(_ step: AIFlowStep) -> String {
        switch step {
        case .listen: "Listen to the audio"
        case .brief: "Episode brief"
        case .scenes: "Describe the scenes"
        case .scriptReview: "Review the script"
        case .translate: "Translate"
        case .join: "Join short lines"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Translate with AI").font(.headline)
            Text(subtitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Text("These steps run in order. Untick what you don't want; a step that is done already runs again when ticked.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let work = editor.workTitle { parts.append(work) }
        let source = editor.briefSourceLanguage
        let target = editor.isTranslating ? editor.track.languageCode : editor.defaultTargetLanguage(avoiding: source)
        if source != "und" { parts.append("\(EditorState.languageName(source)) to \(EditorState.languageName(target))") }
        let lines = editor.sceneFrameLines.count
        if lines > 0 { parts.append(lines == 1 ? "1 line" : "\(lines) lines") }
        return parts.joined(separator: " · ")
    }

    /// Where the run stops for the user, under the row it follows.
    private func stop(after step: AIFlowStep) -> String? {
        switch step {
        case .listen where ticked.contains(.listen) && !editor.isTranslating && !editor.cuesOfTheirOwn.isEmpty:
            "Stops here if the subtitles are off the audio: you decide whether to move them"
        case .scenes where !ticked.isDisjoint(with: [.brief, .scenes]) || editor.track.brief?.isConfirmed == false:
            "Stops here: you confirm the brief"
        case .scriptReview where ticked.contains(.translate) && !editor.isTranslating:
            "Stops here if lines need checking, before they are translated"
        case .join where ticked.contains(.translate):
            "Ends here: you review the choices it was unsure of"
        default:
            nil
        }
    }

    private func rowView(_ row: AIPlanRow) -> some View {
        let step = row.step
        let isOn = ticked.contains(step)
        return HStack(alignment: .center, spacing: 10) {
            Toggle(isOn: Binding(
                get: { ticked.contains(step) },
                set: { on in
                    if on { ticked.insert(step) } else { ticked.remove(step) }
                    // Joining goes with translating, and unticking a step unticks what needs it.
                    if on, step == .translate, editor.aiSettings.joinsLinesAfterTranslating { ticked.insert(.join) }
                    ticked = editor.availableAIPlanTicks(ticked)
                }
            )) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!row.isAvailable)
                .accessibilityLabel(row.title)
                .accessibilityIdentifier(AccessibilityID.AIPlan.tick(step.rawValue))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.title).fontWeight(.medium)
                    if row.isDone {
                        Label("Done", systemImage: "checkmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.green)
                    }
                }
                Text(row.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(row.isAvailable ? .primary : .secondary)
            Spacer(minLength: 8)
            Group {
                modelPicker(step)
                effortPicker(step)
            }
            .disabled(!isOn)
            Text(isOn ? row.cost ?? "" : "")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
        .accessibilityValue(row.isDone ? "Done" : "")
        .accessibilityIdentifier(AccessibilityID.AIPlan.row(step.rawValue))
    }

    @ViewBuilder private func modelPicker(_ step: AIFlowStep) -> some View {
        @Bindable var editor = editor
        Group {
            switch step {
            case .listen:
                Picker("Transcriber", selection: $editor.aiSettings.transcription) {
                    ForEach(AISettings.TranscriptionProvider.allCases) { Text($0.title).tag($0) }
                }
            case .brief:
                helperPicker($editor.aiSettings.brief.model)
            case .scenes:
                helperPicker($editor.aiSettings.scenes.model)
            case .scriptReview:
                helperPicker($editor.aiSettings.scriptReview.model)
            case .translate:
                Picker("Translator", selection: $editor.aiSettings.translation) {
                    ForEach(AISettings.TranslationProvider.allCases) { Text($0.title).tag($0) }
                }
            case .join:
                Color.clear.frame(height: 1)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 220)
        .accessibilityIdentifier(AccessibilityID.AIPlan.model(step.rawValue))
    }

    private func helperPicker(_ model: Binding<AISettings.OpenAIModel>) -> some View {
        Picker("Model", selection: model) {
            ForEach(AISettings.OpenAIModel.allCases) { Text($0.title).tag($0) }
        }
    }

    @ViewBuilder private func effortPicker(_ step: AIFlowStep) -> some View {
        @Bindable var editor = editor
        Group {
            switch step {
            case .brief: effortPicker($editor.aiSettings.brief.effort)
            case .scenes: effortPicker($editor.aiSettings.scenes.effort)
            case .scriptReview: effortPicker($editor.aiSettings.scriptReview.effort)
            case .translate where editor.aiSettings.translation.isCloud: effortPicker($editor.aiSettings.reasoningEffort)
            default: Color.clear.frame(height: 1)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 96)
        .accessibilityIdentifier(AccessibilityID.AIPlan.effort(step.rawValue))
    }

    private func effortPicker(_ effort: Binding<AISettings.ReasoningEffort>) -> some View {
        Picker("Effort", selection: effort) {
            Text("Low").tag(AISettings.ReasoningEffort.low)
            Text("Medium").tag(AISettings.ReasoningEffort.medium)
            Text("High").tag(AISettings.ReasoningEffort.high)
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AccessibilityID.AIPlan.total)
            Spacer()
            Button("Cancel") { editor.dismissAIPlan() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(AccessibilityID.AIPlan.cancelButton)
            Button("Start") { editor.startAIFlow(ticked) }
                .keyboardShortcut(.defaultAction)
                .disabled(ticked.isEmpty)
                .accessibilityIdentifier(AccessibilityID.AIPlan.startButton)
        }
    }

    /// What leaves the Mac with these ticks, and that the costs are rough.
    private var note: String {
        let settings = editor.aiSettings
        var cloud: [String] = []
        if ticked.contains(.listen), settings.transcription.isCloud { cloud.append("the audio") }
        if !ticked.isDisjoint(with: [.brief, .scriptReview]) || (ticked.contains(.translate) && settings.translation.isCloud) { cloud.append("the lines") }
        if ticked.contains(.scenes) { cloud.append("a few frames of each scene") }
        let sent = cloud.isEmpty ? "Nothing leaves this Mac." : "Sent to the cloud: \(cloud.joined(separator: ", "))."
        return sent + " Costs are rough estimates from list prices."
    }
}
