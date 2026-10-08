import AITools
import EditorCommands
import Foundation
import SubtitleCore

/// One step of Translate with AI, in the order they run.
public enum AIFlowStep: String, CaseIterable, Identifiable, Sendable {
    /// Transcribing the audio, or matching a subtitle file's cues to it (speakers, timing).
    case listen
    /// Describing each scene from a few frames of it, without names: the brief reads them next.
    case scenes
    case brief
    case scriptReview
    case translate
    /// Joining short lines after translating.
    case join

    public var id: String { rawValue }

    /// "Episode brief": the step in a few words.
    public var title: String {
        switch self {
        case .listen: "Listen to the audio"
        case .brief: "Episode brief"
        case .scenes: "Describe the scenes"
        case .scriptReview: "Review the script"
        case .translate: "Translate"
        case .join: "Join short lines"
        }
    }
}

/// Which page the window shows.
public enum EditorPage: String, Sendable, CaseIterable {
    /// Translate with AI, stage by stage.
    case translate
    /// The subtitle editor.
    case edit
}

/// A stage of the Translate page: one or more steps, and the point where the user has
/// something to look at. Choices has no step of its own: it is the translation's review.
public enum TranslateStage: String, CaseIterable, Identifiable, Sendable {
    case source
    case brief
    case check
    case translate
    case choices

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .source: "Source"
        case .brief: "Brief"
        case .check: "Check Lines"
        case .translate: "Translate"
        case .choices: "Choices"
        }
    }

    /// What happens at this stage, in a sentence.
    public var explanation: String {
        switch self {
        case .source: "Spotline listens to the audio to learn who says each line and whether the subtitle is on time. A subtitle's own words are not rewritten."
        case .brief: "Who is who, how names are spelled, and what happens in each scene, from the lines, a web lookup and, if you allow it, a few frames of each scene. You confirm it before anything reads it."
        case .check: "Lines to look at before they are translated: words the transcriber was unsure of, and lines where the audio says something else."
        case .translate: "The lines are translated with the brief, the glossary and what the video shows. It runs by itself."
        case .choices: "Lines the target language can say more than one way (who is spoken to, their gender and number), least sure first."
        }
    }

    /// The plan's steps run at this stage.
    public var steps: [AIFlowStep] {
        switch self {
        case .source: [.listen]
        case .brief: [.brief, .scenes]
        case .check: [.scriptReview]
        case .translate: [.translate, .join]
        case .choices: []
        }
    }
}

/// Where a stage stands.
public enum StageState: Equatable, Sendable {
    case done
    case running
    /// It waits for the user.
    case waiting
    case toDo
    /// Nothing ticked here, and nothing done.
    case off
}

/// A run of Translate with AI: the steps ticked in its plan, how far it has got, and
/// what it waits for when it has stopped for the user.
public struct AIFlowRun: Equatable, Sendable {
    public enum Stop: Equatable, Sendable {
        /// The question whether to move the subtitles onto the audio is open.
        case syncQuestion
        /// The episode brief is to be confirmed before anything reads it.
        case confirmBrief
        /// Lines with words to check or an AI Review card, to fix before they are translated.
        case checkLines(Int)
    }

    /// The steps to run, in order.
    public var steps: [AIFlowStep]
    public var finished: Set<AIFlowStep> = []
    /// The step running now, nil between steps and while stopped.
    public var current: AIFlowStep?
    public var stop: Stop?
    /// True once the user chose to translate with lines still to check.
    var translatesUncheckedLines = false

    public init(steps: [AIFlowStep]) {
        self.steps = steps
    }
}

/// What the Translate page shows, worked out once per redraw.
public struct TranslateOverview: Equatable, Sendable {
    public var ticks: Set<AIFlowStep>
    public var rows: [AIPlanRow]
    public var states: [TranslateStage: StageState]
    public var summaries: [TranslateStage: String]
    /// The stage running or waiting, else the first not done.
    public var current: TranslateStage
}

/// A row of the plan: one step as the project stands.
public struct AIPlanRow: Identifiable, Equatable, Sendable {
    public var step: AIFlowStep
    public var title: String
    /// What the step does, or why it is done or cannot run.
    public var detail: String
    /// Already done in this project; ticking it runs it again.
    public var isDone: Bool
    /// Whether it can be ticked, with the other ticks as they are.
    public var isAvailable: Bool
    /// "~4¢", "free", nil when nothing tells.
    public var cost: String?

    public var id: String { step.rawValue }
}

/// Translate with AI: one command opens a plan of every step from the audio to the
/// translated lines, each to tick, with its model and effort; Start runs the ticked
/// ones in order, stopping where the user has something to check (the sync question,
/// the brief to confirm, lines to fix), and the AI bar says where it is. The steps
/// are the same tools the single commands run (docs/ARCHITECTURE.md, section 7e).
extension EditorState {
    // MARK: The plan

    /// What the plan's rows go by, worked out from the project in one pass. Kept until the
    /// project or the settings change, so the Translate page redraws without going over every line.
    struct PlanFacts: Equatable {
        var lines = 0
        var hasMedia = false
        var isTranslating = false
        /// A subtitle file's cues, to match to the audio rather than transcribe.
        var matches = false
        var textIsFromSubtitles = false
        var listened = false
        var translated = false
        var hasBrief = false
        var isBriefConfirmed = false
        var described = false
        var settings = AISettings()
    }

    /// What the facts depend on.
    struct PlanFactsKey: Equatable {
        var track: SubtitleTrack
        var source: SubtitleTrack?
        var transcripts: Int
        var media: URL?
        var settings: AISettings
        var pendingScenes: Bool
    }

    var planFacts: PlanFacts {
        let key = PlanFactsKey(track: track, source: sourceTrack, transcripts: storedTranscripts.count, media: status.mediaURL, settings: aiSettings, pendingScenes: pendingSceneNotes != nil)
        if let cached = cachedPlanFacts, cached.key == key { return cached.facts }
        let facts = PlanFacts(
            lines: sceneFrameLines.count, hasMedia: hasMedia, isTranslating: isTranslating,
            matches: !isTranslating && !cuesOfTheirOwn.isEmpty, textIsFromSubtitles: textIsFromSubtitles,
            listened: !storedTranscripts.isEmpty,
            translated: isTranslating && untranslatedCues.isEmpty && track.cues.contains { !$0.text.isEmpty },
            hasBrief: track.brief != nil, isBriefConfirmed: track.brief?.isConfirmed == true, described: track.brief?.seen.isEmpty == false || pendingSceneNotes != nil,
            settings: aiSettings
        )
        cachedPlanFacts = (key, facts)
        return facts
    }

    /// The plan's rows as the project stands, with `ticked` deciding what depends on what.
    public func aiPlanRows(ticked: Set<AIFlowStep>) -> [AIPlanRow] {
        Self.planRows(planFacts, ticked: ticked)
    }

    static func planRows(_ facts: PlanFacts, ticked: Set<AIFlowStep>) -> [AIPlanRow] {
        let lines = facts.lines, hasMedia = facts.hasMedia, settings = facts.settings
        let hasLines = lines > 0 || (ticked.contains(.listen) && hasMedia)
        let hasBrief = facts.hasBrief || ticked.contains(.brief)
        let matches = facts.matches
        let needsLines = hasMedia ? "Needs lines: tick the first step" : "Needs lines: open a video or import subtitles"

        return [
            AIPlanRow(
                step: .listen, title: matches ? "Match the subtitles to the audio" : "Transcribe the audio",
                detail: !hasMedia ? "Needs the video"
                    : facts.listened ? "Done: the transcript is saved, so running it again uploads nothing"
                    : matches ? "Who says each line, and whether the timing is off" : "Writes the lines, with who says each",
                isDone: facts.listened, isAvailable: hasMedia, cost: nil
            ),
            AIPlanRow(
                step: .scenes, title: "Describe the scenes from the video",
                detail: !hasMedia ? "Needs the video" : !hasLines ? needsLines
                    : facts.described ? "Done: the brief says who is in view"
                    : "Sends a few small frames of each scene; says who is in view, for the brief to read",
                isDone: facts.described, isAvailable: hasMedia && hasLines,
                cost: lines == 0 ? nil : cost(0.03 * Double(lines) / 500 * settings.scenes.model.priceFactor)
            ),
            AIPlanRow(
                step: .brief, title: "Episode brief",
                detail: !hasLines ? needsLines
                    : facts.isBriefConfirmed ? "Done and confirmed" : facts.hasBrief ? "Done, not confirmed yet"
                    :  ticked.contains(.scenes) ? "Who is who, names, terms and scenes, from the lines, the scene descriptions and a web lookup"
                    : "Who is who, names and terms, from the lines and a web lookup",
                isDone: facts.hasBrief, isAvailable: hasLines, cost: cost(0.04 * settings.brief.model.priceFactor)
            ),
            AIPlanRow(
                step: .scriptReview, title: "Review the script",
                detail: facts.isTranslating ? "The source lines can't be changed while translating" : !hasLines ? needsLines
                    : !hasBrief ? "Needs the episode brief"
                    : facts.textIsFromSubtitles && !ticked.contains(.listen) || matches ? "Not needed for a subtitle file: its words were not misheard"
                    : "Flags lines that look misheard, with fixes to try",
                isDone: false, isAvailable: !facts.isTranslating && hasLines && hasBrief,
                cost: lines == 0 ? nil : cost(0.03 * Double(lines) / 700 * settings.scriptReview.model.priceFactor)
            ),
            AIPlanRow(
                step: .translate, title: "Translate",
                detail: !hasLines ? needsLines : facts.translated ? "Done: every line is translated"
                    : "With the brief, the glossary and what the video shows",
                isDone: facts.translated, isAvailable: hasLines,
                cost: lines == 0 ? nil : cost(Double(lines) * costPerLine(settings.translation))
            ),
            AIPlanRow(
                step: .join, title: "Join short lines",
                detail: ticked.contains(.translate) ? "Makes two-line cues of short neighbours, on this Mac" : "Runs after translating",
                isDone: false, isAvailable: ticked.contains(.translate) && hasLines, cost: "free"
            ),
        ]
    }

    /// The steps ticked when the plan opens: those not done yet, as the settings last had them.
    public var defaultAIPlanTicks: Set<AIFlowStep> {
        Self.defaultTicks(planFacts)
    }

    static func defaultTicks(_ facts: PlanFacts) -> Set<AIFlowStep> {
        let settings = facts.settings
        var ticked: Set<AIFlowStep> = []
        for step in AIFlowStep.allCases {
            guard let row = planRows(facts, ticked: ticked).first(where: { $0.step == step }), row.isAvailable, !row.isDone else { continue }
            let wanted: Bool = switch step {
            case .listen, .translate: true
            case .brief: settings.buildsBrief
            case .scenes: settings.sendsVideoFrames && settings.allowsCloud
            // A subtitle file's words were not misheard.
            case .scriptReview: settings.reviewsScript && !(facts.textIsFromSubtitles || facts.matches)
            case .join: settings.joinsLinesAfterTranslating
            }
            if wanted { ticked.insert(step) }
        }
        return ticked
    }

    /// `ticked` without the steps that cannot run as it stands (their step before was unticked).
    public func availableAIPlanTicks(_ ticked: Set<AIFlowStep>) -> Set<AIFlowStep> {
        Self.availableTicks(ticked, planFacts)
    }

    static func availableTicks(_ ticked: Set<AIFlowStep>, _ facts: PlanFacts) -> Set<AIFlowStep> {
        var kept = ticked
        // Unticking one step can take the next with it, and so on down.
        for _ in AIFlowStep.allCases {
            let available = Set(planRows(facts, ticked: kept).filter(\.isAvailable).map(\.step))
            kept.formIntersection(available)
        }
        return kept
    }

    /// Rough list-price cost of translating one line at medium effort, in dollars (estimates, not measured).
    static func costPerLine(_ provider: AISettings.TranslationProvider) -> Double {
        switch provider {
        case .appleTranslation: 0
        case .claude: 0.0049
        case .claudeSonnet: 0.0024
        case .openAILuna, .claudeHaiku: 0.00014
        }
    }

    /// "free", "~4¢", "~$3.40".
    static func cost(_ dollars: Double) -> String {
        if dollars <= 0 { return "free" }
        if dollars < 0.995 { return "~\(max(Int((dollars * 100).rounded()), 1))¢" }
        return "~$" + String(format: "%.2f", dollars)
    }

    // MARK: Running it

    /// The steps ticked on the Translate page: those chosen there, else the defaults for the project as it stands.
    public var planTicks: Set<AIFlowStep> {
        _ = planTicksVersion
        let facts = planFacts
        return Self.availableTicks(chosenPlanTicks ?? Self.defaultTicks(facts), facts)
    }

    /// Ticks or unticks a step on the Translate page. Joining goes with translating, and
    /// unticking a step unticks what needs it.
    public func setPlanTick(_ step: AIFlowStep, _ on: Bool) {
        var ticked = planTicks
        if on {
            ticked.insert(step)
            if step == .translate, aiSettings.joinsLinesAfterTranslating { ticked.insert(.join) }
        } else {
            ticked.remove(step)
        }
        chosenPlanTicks = availableAIPlanTicks(ticked)
        planTicksVersion += 1
    }

    // MARK: Stages

    /// Where a stage of the Translate page stands, from the run and the project.
    public func stageState(_ stage: TranslateStage, ticks: Set<AIFlowStep>? = nil) -> StageState {
        if let run = aiFlow {
            if let current = run.current, stage.steps.contains(current) { return .running }
            switch (run.stop, stage) {
            case (.syncQuestion, .source), (.confirmBrief, .brief), (.checkLines, .check): return .waiting
            default: break
            }
        }
        if isStageDone(stage) { return .done }
        let ticked = ticks ?? planTicks
        return stage == .choices ? .toDo : stage.steps.contains(where: ticked.contains) ? .toDo : .off
    }

    private func isStageDone(_ stage: TranslateStage) -> Bool {
        let translated = planFacts.translated
        switch stage {
        case .source: return !storedTranscripts.isEmpty
        case .brief: return track.brief?.isConfirmed == true
        case .check: return translated || (track.brief?.isConfirmed == true && linesToCheckBeforeTranslating == 0 && aiFlow?.current != .scriptReview)
        case .translate: return translated
        case .choices: return translated && cuesToChoose.isEmpty
        }
    }

    /// The stage's line in the list: where it stands, in a few words.
    public func stageSummary(_ stage: TranslateStage, ticks: Set<AIFlowStep>? = nil, state known: StageState? = nil) -> String {
        let ticks = ticks ?? planTicks
        let state = known ?? stageState(stage, ticks: ticks)
        if state == .running, let task = aiTask { return task.detail }
        switch stage {
        case .source:
            if state == .waiting { return "Decide on the timing" }
            if state == .done { return !isTranslating && !cuesOfTheirOwn.isEmpty ? "Matched to the audio" : "Listened to the audio" }
            return state == .off ? "Not ticked" : hasMedia ? "To do" : "Needs the video"
        case .brief:
            if state == .waiting || track.brief?.isConfirmed == false { return "Waiting for you to confirm" }
            if state == .done { return track.brief?.seen.isEmpty == false ? "Confirmed, with the video's scenes" : "Confirmed" }
            return state == .off ? "Not ticked" : "To do"
        case .check:
            let count = linesToCheckBeforeTranslating
            if count > 0 { return count == 1 ? "1 line to check" : "\(count) lines to check" }
            if state == .done { return "Nothing to check" }
            return state == .off ? "Not ticked" : "After the brief"
        case .translate:
            if state == .done { return track.cues.count == 1 ? "1 line translated" : "\(track.cues.count) lines translated" }
            let cost = aiPlanRows(ticked: ticks).first { $0.step == .translate }?.cost
            return state == .off ? "Not ticked" : AITaskStatus.shortName(aiSettings.translation.title) + (cost.map { " · \($0)" } ?? "")
        case .choices:
            let open = cuesToChoose.count
            if open > 0 { return open == 1 ? "1 to confirm" : "\(open) to confirm" }
            return state == .done ? "All settled" : "After translating"
        }
    }

    /// The lines to check before translating, on the Edit page with the review beside them.
    public func showLinesToCheck() {
        page = .edit
        wantsReviewSidebar = true
    }

    /// The stage the page shows by itself: the one running or waiting, else the first not done.
    public var currentStage: TranslateStage {
        translateOverview.current
    }

    /// Everything the Translate page shows, worked out once: the ticks, the rows, and each stage's state and line.
    public var translateOverview: TranslateOverview {
        let ticks = planTicks
        let rows = aiPlanRows(ticked: ticks)
        var states: [TranslateStage: StageState] = [:]
        var summaries: [TranslateStage: String] = [:]
        for stage in TranslateStage.allCases {
            let state = stageState(stage, ticks: ticks)
            states[stage] = state
            summaries[stage] = stageSummary(stage, ticks: ticks, state: state)
        }
        let stages = TranslateStage.allCases
        let current = stages.first { [.running, .waiting].contains(states[$0]) }
            ?? stages.first { ![.done, .off].contains(states[$0]) } ?? .choices
        return TranslateOverview(ticks: ticks, rows: rows, states: states, summaries: summaries, current: current)
    }

    /// Starts the ticked steps (the plan's Start). The ticks are remembered as the settings the single commands follow too.
    public func startAIFlow(_ ticked: Set<AIFlowStep>) {
        let ticked = availableAIPlanTicks(ticked)
        guard !ticked.isEmpty, aiTask == nil else { return }
        // The ticks are kept as settings; next time the page ticks what is left to do.
        chosenPlanTicks = nil
        planTicksVersion += 1
        let rows = aiPlanRows(ticked: ticked)
        func isOffByChoice(_ step: AIFlowStep) -> Bool {
            !ticked.contains(step) && rows.first { $0.step == step }.map { $0.isAvailable && !$0.isDone } == true
        }
        if ticked.contains(.brief) { aiSettings.buildsBrief = true } else if isOffByChoice(.brief) { aiSettings.buildsBrief = false }
        if ticked.contains(.scenes) { aiSettings.sendsVideoFrames = true } else if isOffByChoice(.scenes) { aiSettings.sendsVideoFrames = false }
        if ticked.contains(.scriptReview) { aiSettings.reviewsScript = true } else if isOffByChoice(.scriptReview), !textIsFromSubtitles { aiSettings.reviewsScript = false }
        if ticked.contains(.translate) { aiSettings.joinsLinesAfterTranslating = ticked.contains(.join) }
        aiFlow = AIFlowRun(steps: AIFlowStep.allCases.filter(ticked.contains))
        advanceAIFlow()
    }

    /// Lines the user would fix before they are translated: words to check and AI Review cards.
    var linesToCheckBeforeTranslating: Int {
        isTranslating ? 0 : track.cues.count(where: { $0.scriptFinding != nil || $0.unsureWords?.isEmpty == false })
    }

    /// Runs the next step of the flow, or stops for the user where something is theirs to check.
    func advanceAIFlow() {
        guard var run = aiFlow, aiTask == nil else { return }
        run.stop = nil
        run.current = nil
        if subtitleSync != nil {
            run.stop = .syncQuestion
            aiFlow = run
            return
        }
        guard let next = run.steps.first(where: { !run.finished.contains($0) }) else {
            aiFlow = nil
            // A brief nobody has seen yet is shown, and whatever there is to review.
            if track.brief?.isConfirmed == false, !run.finished.isDisjoint(with: [.brief, .scenes]) { isBriefSheetShown = true }
            if !reviewItems(in: .all).isEmpty { wantsReviewSidebar = true }
            return
        }
        // The brief is confirmed before anything reads it.
        if next == .scriptReview || next == .translate, track.brief?.isConfirmed == false {
            run.stop = .confirmBrief
            aiFlow = run
            isBriefSheetShown = true
            return
        }
        if next == .translate, !run.translatesUncheckedLines, linesToCheckBeforeTranslating > 0 {
            run.stop = .checkLines(linesToCheckBeforeTranslating)
            aiFlow = run
            wantsReviewSidebar = true
            return
        }
        run.current = next
        aiFlow = run
        switch next {
        case .listen:
            transcribe()
        case .brief:
            isBriefSheetShown = false
            buildEpisodeBrief(automatically: false)
        case .scenes:
            isBriefSheetShown = false
            describeScenes(automatically: false)
        case .scriptReview:
            reviewScript(automatically: false)
        case .translate:
            if !isTranslating { useCuesAsSource() }
            translateUntranslatedCues()
        case .join:
            // Joined with the translation, by the setting.
            aiFlowFinished(.join)
            return
        }
        // The step could not start (its error was shown). The helper steps are passed over; without the rest there is no flow.
        guard aiTask == nil, aiFlow?.current == next else { return }
        if next == .scenes || next == .scriptReview { aiFlowFinished(next) } else { aiFlow = nil }
    }

    /// A step of the flow is done: on to the next.
    func aiFlowFinished(_ step: AIFlowStep) {
        guard aiFlow != nil else { return }
        aiFlow?.finished.insert(step)
        if step == .translate { aiFlow?.finished.insert(.join) }
        aiFlow?.current = nil
        advanceAIFlow()
    }

    /// A step failed or was cancelled: the flow ends where it is. What was done stays.
    func endAIFlow() {
        aiFlow = nil
    }

    /// The stopped flow's button: translates with lines still to check, or shows the brief to confirm again.
    func continueAIFlow() {
        guard let run = aiFlow, aiTask == nil else { return }
        switch run.stop {
        case .checkLines:
            aiFlow?.translatesUncheckedLines = true
            advanceAIFlow()
        case .confirmBrief:
            isBriefSheetShown = true
        case .syncQuestion, nil:
            advanceAIFlow()
        }
    }

    /// What the AI bar says while the flow waits for the user, nil while it runs.
    public var aiFlowStopText: String? {
        switch aiFlow?.stop {
        case .confirmBrief: "Confirm the episode brief to go on"
        case .checkLines(let count): count == 1 ? "1 line to check before translating" : "\(count) lines to check before translating"
        case .syncQuestion, nil: nil
        }
    }

    /// The stopped flow's button title.
    public var aiFlowContinueTitle: String {
        if case .confirmBrief = aiFlow?.stop { return "Open Brief" }
        return "Translate Anyway"
    }

    func canPerformAIFlow(_ command: EditorCommand) -> Bool {
        switch command.id {
        case EditorCommand.planAIFlow.id: true
        case EditorCommand.continueAIFlow.id: aiTask == nil && aiFlowStopText != nil
        default: false
        }
    }

    func performAIFlow(_ command: EditorCommand) -> Bool {
        guard canPerformAIFlow(command) else { return false }
        switch command.id {
        case EditorCommand.planAIFlow.id: page = .translate
        case EditorCommand.continueAIFlow.id: continueAIFlow()
        default: return false
        }
        return true
    }
}
