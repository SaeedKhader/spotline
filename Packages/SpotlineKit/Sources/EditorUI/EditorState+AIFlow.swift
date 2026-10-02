import AITools
import EditorCommands
import Foundation
import SubtitleCore

/// One step of Translate with AI, in the order they run.
public enum AIFlowStep: String, CaseIterable, Identifiable, Sendable {
    /// Transcribing the audio, or matching a subtitle file's cues to it (speakers, timing).
    case listen
    case brief
    /// Describing each scene from a few frames of it, into the brief.
    case scenes
    case scriptReview
    case translate
    /// Joining short lines after translating.
    case join

    public var id: String { rawValue }
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

    /// Whether there are lines to work on, or will be once the audio is transcribed.
    private func hasLines(_ ticked: Set<AIFlowStep>) -> Bool {
        !sceneFrameLines.isEmpty || (ticked.contains(.listen) && hasMedia)
    }

    /// The plan's rows as the project stands, with `ticked` deciding what depends on what.
    public func aiPlanRows(ticked: Set<AIFlowStep>) -> [AIPlanRow] {
        let lines = sceneFrameLines.count
        let hasLines = hasLines(ticked)
        let brief = track.brief
        let hasBrief = brief != nil || ticked.contains(.brief)
        let matches = !isTranslating && !cuesOfTheirOwn.isEmpty
        let listened = !storedTranscripts.isEmpty
        let translated = isTranslating && untranslatedCues.isEmpty && track.cues.contains { !$0.text.isEmpty }
        let described = brief?.seen.isEmpty == false
        let needsLines = hasMedia ? "Needs lines: tick the first step" : "Needs lines: open a video or import subtitles"

        return [
            AIPlanRow(
                step: .listen, title: matches ? "Match the subtitles to the audio" : "Transcribe the audio",
                detail: !hasMedia ? "Needs the video"
                    : listened ? "Done: the transcript is saved, so running it again uploads nothing"
                    : matches ? "Who says each line, and whether the timing is off" : "Writes the lines, with who says each",
                isDone: listened, isAvailable: hasMedia, cost: nil
            ),
            AIPlanRow(
                step: .brief, title: "Episode brief",
                detail: !hasLines ? needsLines
                    : brief?.isConfirmed == true ? "Done and confirmed" : brief != nil ? "Done, not confirmed yet"
                    : "Who is who, names and terms, from the lines and a web lookup",
                isDone: brief != nil, isAvailable: hasLines, cost: Self.cost(0.04 * aiSettings.brief.model.priceFactor)
            ),
            AIPlanRow(
                step: .scenes, title: "Describe the scenes from the video",
                detail: !hasMedia ? "Needs the video" : !hasLines ? needsLines : !hasBrief ? "Needs the episode brief"
                    : described ? "Done: the brief says who is in view"
                    : "Sends a few small frames of each scene; says who is in view",
                isDone: described, isAvailable: hasMedia && hasLines && hasBrief,
                cost: lines == 0 ? nil : Self.cost(0.03 * Double(lines) / 500 * aiSettings.scenes.model.priceFactor)
            ),
            AIPlanRow(
                step: .scriptReview, title: "Review the script",
                detail: isTranslating ? "The source lines can't be changed while translating" : !hasLines ? needsLines
                    : !hasBrief ? "Needs the episode brief"
                    : textIsFromSubtitles && !ticked.contains(.listen) || matches ? "Not needed for a subtitle file: its words were not misheard"
                    : "Flags lines that look misheard, with fixes to try",
                isDone: false, isAvailable: !isTranslating && hasLines && hasBrief,
                cost: lines == 0 ? nil : Self.cost(0.03 * Double(lines) / 700 * aiSettings.scriptReview.model.priceFactor)
            ),
            AIPlanRow(
                step: .translate, title: "Translate",
                detail: !hasLines ? needsLines : translated ? "Done: every line is translated"
                    : "With the brief, the glossary and what the video shows",
                isDone: translated, isAvailable: hasLines,
                cost: lines == 0 ? nil : Self.cost(Double(lines) * Self.costPerLine(aiSettings.translation))
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
        var ticked: Set<AIFlowStep> = []
        for step in AIFlowStep.allCases {
            guard let row = aiPlanRows(ticked: ticked).first(where: { $0.step == step }), row.isAvailable, !row.isDone else { continue }
            let wanted: Bool = switch step {
            case .listen, .translate: true
            case .brief: aiSettings.buildsBrief
            case .scenes: aiSettings.sendsVideoFrames && aiSettings.allowsCloud
            // A subtitle file's words were not misheard.
            case .scriptReview: aiSettings.reviewsScript && !(textIsFromSubtitles || (!isTranslating && !cuesOfTheirOwn.isEmpty))
            case .join: aiSettings.joinsLinesAfterTranslating
            }
            if wanted { ticked.insert(step) }
        }
        return ticked
    }

    /// `ticked` without the steps that cannot run as it stands (their step before was unticked).
    public func availableAIPlanTicks(_ ticked: Set<AIFlowStep>) -> Set<AIFlowStep> {
        var kept = ticked
        // Unticking one step can take the next with it, and so on down.
        for _ in AIFlowStep.allCases {
            let available = Set(aiPlanRows(ticked: kept).filter(\.isAvailable).map(\.step))
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
        case .openAILuna: 0.00014
        }
    }

    /// "free", "~4¢", "~$3.40".
    static func cost(_ dollars: Double) -> String {
        if dollars <= 0 { return "free" }
        if dollars < 0.995 { return "~\(max(Int((dollars * 100).rounded()), 1))¢" }
        return "~$" + String(format: "%.2f", dollars)
    }

    // MARK: Running it

    func showAIPlan() {
        isAIPlanShown = true
    }

    public func dismissAIPlan() {
        isAIPlanShown = false
    }

    /// Starts the ticked steps (the plan's Start). The ticks are remembered as the settings the single commands follow too.
    public func startAIFlow(_ ticked: Set<AIFlowStep>) {
        let ticked = availableAIPlanTicks(ticked)
        isAIPlanShown = false
        guard !ticked.isEmpty, aiTask == nil else { return }
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
        case EditorCommand.planAIFlow.id: aiTask == nil && pendingReview == nil && aiFlow == nil && (hasMedia || !track.cues.isEmpty)
        case EditorCommand.continueAIFlow.id: aiTask == nil && aiFlowStopText != nil
        default: false
        }
    }

    func performAIFlow(_ command: EditorCommand) -> Bool {
        guard canPerformAIFlow(command) else { return false }
        switch command.id {
        case EditorCommand.planAIFlow.id: showAIPlan()
        case EditorCommand.continueAIFlow.id: continueAIFlow()
        default: return false
        }
        return true
    }
}
