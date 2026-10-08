import AITools
import EditorCommands
import SpotlineAccessibility
import SubtitleCore
import SwiftUI

/// The Translate page: Translate with AI, stage by stage. On the left the stages
/// (Source, Brief, Check Lines, Translate, Choices), each with where it stands; on
/// the right the chosen stage: what happens there, its steps to tick with their
/// model, effort and rough cost, and, while it runs or waits for the user, how far
/// it has got or what it waits for. The page follows the run; clicking a stage shows it.
struct TranslatePage: View {
    let editor: EditorState
    /// The stage clicked, nil to follow the run.
    @State private var picked: TranslateStage?

    var body: some View {
        let overview = editor.translateOverview
        let shown = picked ?? overview.current
        HStack(spacing: 0) {
            StageList(editor: editor, overview: overview, shown: shown) { stage in
                picked = stage == overview.current ? nil : stage
            }
            .frame(width: 280)
            Divider()
            ScrollView {
                StageScreen(editor: editor, overview: overview, stage: shown)
                    .padding(24)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // A new stage running or waiting is shown, whatever was clicked before.
        .onChange(of: overview.current) { picked = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.TranslatePage.root)
    }
}

/// The stages down the left, the work above them and Start or Stop below.
private struct StageList: View {
    let editor: EditorState
    let overview: TranslateOverview
    let shown: TranslateStage
    let show: (TranslateStage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(editor.workTitle ?? "Translate").font(.headline).lineLimit(2)
                Text(languages).font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            ForEach(TranslateStage.allCases) { stage in
                Button { show(stage) } label: { row(stage) }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(overview.summaries[stage] ?? "")
                    .accessibilityIdentifier(AccessibilityID.TranslatePage.stage(stage.rawValue))
            }
            Spacer()
            footer
        }
        .padding(12)
    }

    private var languages: String {
        let source = editor.briefSourceLanguage
        let target = editor.isTranslating ? editor.track.languageCode : editor.defaultTargetLanguage(avoiding: source)
        return source == "und" ? "To \(EditorState.languageName(target))"
            : "\(EditorState.languageName(source)) to \(EditorState.languageName(target))"
    }

    private func row(_ stage: TranslateStage) -> some View {
        let state = overview.states[stage] ?? .toDo
        return HStack(alignment: .top, spacing: 10) {
            StageIcon(state: state).frame(width: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(stage.title).fontWeight(stage == shown ? .semibold : .regular)
                Text(overview.summaries[stage] ?? "")
                    .font(.caption)
                    .foregroundStyle(state == .waiting ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(state == .off ? .secondary : .primary)
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 7).fill(stage == shown ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.clear)))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editor.aiFlow != nil {
                CommandButton(command: .cancelAITask, editor: editor)
            } else {
                Button { editor.startAIFlow(overview.ticks) } label: {
                    Text("Start").frame(maxWidth: .infinity)
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(overview.ticks.isEmpty || editor.aiTask != nil)
                    .accessibilityIdentifier(AccessibilityID.TranslatePage.startButton)
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
    }

    /// What leaves the Mac with these ticks, and that the costs are rough.
    private var note: String {
        let ticked = overview.ticks, settings = editor.aiSettings
        var cloud: [String] = []
        if ticked.contains(.listen), settings.transcription.isCloud { cloud.append("the audio") }
        if !ticked.isDisjoint(with: [.brief, .scriptReview]) || (ticked.contains(.translate) && settings.translation.isCloud) { cloud.append("the lines") }
        if ticked.contains(.scenes) { cloud.append("a few frames of each scene") }
        if ticked.isEmpty { return "Tick a step to start." }
        return (cloud.isEmpty ? "Nothing leaves this Mac." : "Sent to the cloud: \(cloud.joined(separator: ", ")).") + " Costs are rough estimates."
    }
}

private struct StageIcon: View {
    let state: StageState

    var body: some View {
        switch state {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .running: ProgressView().controlSize(.small)
        case .waiting: Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        case .toDo: Image(systemName: "circle").foregroundStyle(.secondary)
        case .off: Image(systemName: "minus.circle").foregroundStyle(.tertiary)
        }
    }
}

/// One stage: what happens there, its steps, and where it stands.
private struct StageScreen: View {
    let editor: EditorState
    let overview: TranslateOverview
    let stage: TranslateStage

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(stage.title).font(.title2.weight(.semibold))
                Text(stage.explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            status
            if !stage.steps.isEmpty {
                let rows = overview.rows.filter { stage.steps.contains($0.step) }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        Divider()
                        PlanStepRow(editor: editor, row: row, isOn: overview.ticks.contains(row.step))
                    }
                    Divider()
                }
                .disabled(editor.aiFlow != nil)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.TranslatePage.screen(stage.rawValue))
    }

    /// While the stage runs, the running tool's progress; while it waits, what for and the button to go on.
    @ViewBuilder private var status: some View {
        switch overview.states[stage] ?? .toDo {
        case .running:
            if let task = editor.aiTask {
                AITaskProgress(task: task)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            }
        case .waiting:
            waiting
        default:
            if stage == .choices, !editor.cuesToChoose.isEmpty {
                box("\((overview.summaries[.choices] ?? "")). For now they are reviewed on the Edit page, beside the lines.") {
                    Button("Review Choices") {
                        editor.perform(.showEditPage)
                        editor.perform(.reviewChoices)
                    }
                }
            } else if stage == .check, editor.linesToCheckBeforeTranslating > 0, editor.aiFlow == nil {
                box("\((overview.summaries[.check] ?? "")). For now they are reviewed on the Edit page, beside the lines.") {
                    Button("Show Them") { editor.showLinesToCheck() }
                }
            }
        }
    }

    @ViewBuilder private var waiting: some View {
        switch editor.aiFlow?.stop {
        case .confirmBrief:
            box("The brief is ready. Check who is who and confirm it; the run goes on from there.") {
                CommandButton(command: .showEpisodeBrief, editor: editor)
            }
        case .checkLines:
            box("\((overview.summaries[.check] ?? "")) before translating. Fix them on the Edit page, or translate them as they are.") {
                Button("Show Them") { editor.showLinesToCheck() }
                Button(editor.aiFlowContinueTitle) { editor.perform(.continueAIFlow) }
                    .accessibilityIdentifier(AccessibilityID.command(EditorCommand.continueAIFlow.id))
            }
        case .syncQuestion:
            box("The subtitle is off the audio. Answer the question to go on.") { EmptyView() }
        case nil:
            EmptyView()
        }
    }

    private func box(_ text: String, @ViewBuilder buttons: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(text, systemImage: "pause.circle")
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AccessibilityID.TranslatePage.waiting)
            HStack { buttons() }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}

/// A step of the plan: its tick, what it does, its model and effort, and a rough cost.
struct PlanStepRow: View {
    let editor: EditorState
    let row: AIPlanRow
    let isOn: Bool

    var body: some View {
        let step = row.step
        HStack(alignment: .center, spacing: 10) {
            Toggle(isOn: Binding(get: { isOn }, set: { editor.setPlanTick(step, $0) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!row.isAvailable)
                .accessibilityLabel(row.title)
                .accessibilityIdentifier(AccessibilityID.AIPlan.tick(step.rawValue))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.title).fontWeight(.medium)
                    if row.isDone {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
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
        .padding(.vertical, 8)
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
            case .brief: helperPicker($editor.aiSettings.brief.model)
            case .scenes: helperPicker($editor.aiSettings.scenes.model)
            case .scriptReview: helperPicker($editor.aiSettings.scriptReview.model)
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

    private func helperPicker(_ model: Binding<AISettings.HelperModel>) -> some View {
        Picker("Model", selection: model) {
            ForEach(AISettings.HelperModel.allCases) { Text($0.title).tag($0) }
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
}

/// The switch under the window between the Translate and Edit pages.
struct PageSwitcher: View {
    let editor: EditorState

    var body: some View {
        Picker("Page", selection: Binding(get: { editor.page }, set: { editor.perform($0 == .translate ? .showTranslatePage : .showEditPage) })) {
            Text("Translate").tag(EditorPage.translate)
            Text("Edit").tag(EditorPage.edit)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 220)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier(AccessibilityID.TranslatePage.switcher)
    }
}
