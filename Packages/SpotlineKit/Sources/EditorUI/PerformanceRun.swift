import AppKit
import EditorCommands
import Foundation
import SubtitleCore

/// Times how long the main thread is busy between two waits of its run loop:
/// while it is busy nothing is drawn and no click or key is answered, so a busy
/// stretch longer than a frame is a hitch the person can see.
@MainActor
final class MainThreadMonitor {
    /// A stretch of work, in seconds since the Mac started.
    private struct Stretch {
        var end: Double
        var duration: Double
    }

    private var stretches: [Stretch] = []
    private var busySince: Double?
    private var observers: [CFRunLoopObserver] = []
    /// How long the main thread took to answer each ping from another thread: what a click or key would have waited.
    private var waits: [Stretch] = []
    private var pinger: DispatchSourceTimer?
    private let pingSent = PingTime()

    nonisolated static var now: Double { ProcessInfo.processInfo.systemUptime }

    func start() {
        guard observers.isEmpty else { return }
        busySince = Self.now
        // Woken first of all, asleep last of all, so the stretch holds everything done in between.
        let begin = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.busySince = Self.now }
        }
        let end = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.endStretch() }
        }
        for observer in [begin, end].compactMap(\.self) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
        // A ping every 10 ms, one at a time: the main thread answers it when it gets to it.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { @Sendable [weak self, pingSent] in
            let sent = Self.now
            guard pingSent.take(sent) else { return }
            DispatchQueue.main.async {
                let now = Self.now
                pingSent.clear()
                MainActor.assumeIsolated { self?.waits.append(Stretch(end: now, duration: now - sent)) }
            }
        }
        timer.resume()
        pinger = timer
    }

    private func endStretch() {
        guard let since = busySince else { return }
        let now = Self.now
        stretches.append(Stretch(end: now, duration: now - since))
        busySince = nil
    }

    /// The work done since `start` (a time from `now`), the stretch under way included.
    func load(since start: Double) -> MainThreadLoad {
        let now = Self.now
        // Both lists are in time order: only their ends are read.
        func since(_ list: [Stretch]) -> [Double] {
            var found: [Double] = []
            for stretch in list.reversed() {
                guard stretch.end >= start else { break }
                found.append(stretch.duration)
            }
            return found
        }
        var durations = since(stretches)
        if let busy = busySince { durations.append(now - busy) }
        // A ping still unanswered has waited since it was sent.
        var answers = since(waits).map { $0 * 1000 }
        if let sent = pingSent.value { answers.append((now - sent) * 1000) }
        return MainThreadLoad(
            seconds: now - start, busyMs: durations.reduce(0, +) * 1000, longestMs: answers.max() ?? 0,
            over16: answers.count { $0 > 1000.0 / 60 }, over50: answers.count { $0 > 50 }, over100: answers.count { $0 > 100 }
        )
    }
}

/// When the ping the main thread has yet to answer was sent; nil when it has answered.
private final class PingTime: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: Double?

    var value: Double? { lock.withLock { sent } }

    /// Notes a ping as sent, unless one is still waiting.
    func take(_ time: Double) -> Bool {
        lock.withLock {
            guard sent == nil else { return false }
            sent = time
            return true
        }
    }

    func clear() { lock.withLock { sent = nil } }
}

/// What the main thread did over a stretch of time.
struct MainThreadLoad: Codable {
    /// How long was watched.
    var seconds: Double
    /// Main-thread work in that time.
    var busyMs: Double
    /// The longest the main thread took to answer: how long a click or key waited, at worst.
    var longestMs: Double
    /// Times it took longer than a 60 Hz frame, than 50 ms and than 100 ms to answer.
    var over16: Int
    var over50: Int
    var over100: Int

    var busyPercent: Double { seconds > 0 ? busyMs / (seconds * 10) : 0 }
}

/// One action done many times: what each cost.
struct ActionCost: Codable {
    var count: Int
    /// The action's own code, before anything redraws.
    var modelMedianMs: Double
    var modelWorstMs: Double
    /// All main-thread work until the app is at rest again (the action, then redrawing).
    var medianMs: Double
    var p90Ms: Double
    var worstMs: Double
    /// The longest the app did not answer after one action.
    var longestStallMs: Double

    init(_ steps: [(model: Double, load: MainThreadLoad)]) {
        count = steps.count
        let model = steps.map(\.model).sorted()
        let busy = steps.map(\.load.busyMs).sorted()
        func pick(_ values: [Double], _ fraction: Double) -> Double {
            values.isEmpty ? 0 : values[min(Int((Double(values.count) * fraction).rounded(.down)), values.count - 1)]
        }
        modelMedianMs = pick(model, 0.5)
        modelWorstMs = model.last ?? 0
        medianMs = pick(busy, 0.5)
        p90Ms = pick(busy, 0.9)
        worstMs = busy.last ?? 0
        longestStallMs = steps.map(\.load.longestMs).max() ?? 0
    }
}

/// What a performance run measured (`-PerfReport <file>`, `scripts/perf.sh`).
struct PerformanceReport: Codable {
    struct Project: Codable {
        var cues = 0
        var sourceCues = 0
        var isTranslating = false
        var reviewCards = 0
        var cardsByFilter: [String: Int] = [:]
        var glossaryTerms = 0
        var transcriptWords = 0
        var shotChanges = 0
        var mediaSeconds = 0.0
    }

    struct Scroll: Codable {
        var load: MainThreadLoad
        /// Scroll steps made a second, of 60 asked for.
        var stepsPerSecond: Double
    }

    var project = Project()
    /// False when the window was covered, and so drew nothing: the numbers are then too low.
    var windowWasVisible = false
    /// From launch until the project's cues and video are in the window, and the main-thread work in that time.
    var openSeconds = 0.0
    var open: MainThreadLoad?
    /// Paused, nothing happening.
    var idle: MainThreadLoad?
    var playback: MainThreadLoad?
    var selectNextCue: ActionCost?
    var jumpToFarCue: ActionCost?
    var typeCharacter: ActionCost?
    var undo: ActionCost?
    var nextReviewCard: ActionCost?
    var switchReviewFilter: ActionCost?
    var scrollCueList: Scroll?
    var scrollReview: Scroll?
    /// Single calls, in milliseconds (an average of several).
    var calls: [String: Double] = [:]
}

/// Runs the same things a person does (open, play, select, type, review, scroll) by itself and
/// writes what each cost to a file: the app's speed as a number, to compare before and after a
/// change. Started by `-PerfReport <file>` with `-OpenProject <project>`; `scripts/perf.sh` runs
/// it on a copy of a project, so nothing of the person's changes.
@MainActor
public enum PerformanceRun {
    private static let monitor = MainThreadMonitor()

    public static func start(workspace: EditorWorkspace, reportURL: URL, quitsWhenDone: Bool) {
        monitor.start()
        let launched = processStart ?? MainThreadMonitor.now
        Task { @MainActor in
            var report = PerformanceReport()
            // Open: until the cues and the video are there.
            let deadline = MainThreadMonitor.now + 60
            while MainThreadMonitor.now < deadline {
                if let editor = workspace.activeEditor, !editor.track.cues.isEmpty, editor.hasMedia, editor.status.duration != nil { break }
                try? await Task.sleep(for: .milliseconds(5))
            }
            guard let editor = workspace.activeEditor, !editor.track.cues.isEmpty else {
                try? Data("No project with cues opened.".utf8).write(to: reportURL)
                if quitsWhenDone { exit(0) }
                return
            }
            let window = NSApp.windows.first { $0.identifier?.rawValue == "main" }
            window?.orderFrontRegardless()
            // One more turn, so the first frame with the cues in it is drawn.
            try? await Task.sleep(for: .milliseconds(50))
            report.openSeconds = MainThreadMonitor.now - launched
            report.open = monitor.load(since: launched)
            // Analysis read from the project, the seek to where the playhead was.
            try? await Task.sleep(for: .seconds(3))
            report.windowWasVisible = window?.occlusionState.contains(.visible) ?? false
            report.project = facts(of: editor)

            await run(editor, window: window, into: &report)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(report).write(to: reportURL)
            // The project is a throwaway copy: leave at once, without the document saving on the way out.
            if quitsWhenDone { exit(0) }
        }
    }

    private static func facts(of editor: EditorState) -> PerformanceReport.Project {
        var project = PerformanceReport.Project()
        project.cues = editor.track.cues.count
        project.sourceCues = editor.sourceTrack?.cues.count ?? 0
        project.isTranslating = editor.isTranslating
        project.reviewCards = editor.reviewItems(in: .all).count
        for scope in ReviewScope.allCases where scope != .all {
            project.cardsByFilter[scope.rawValue] = editor.reviewItems(in: scope).count
        }
        project.glossaryTerms = editor.glossary.entries.count
        project.transcriptWords = editor.storedTranscripts.last?.words.count ?? 0
        project.shotChanges = editor.shotChanges?.count ?? 0
        project.mediaSeconds = editor.status.duration?.seconds ?? 0
        return project
    }

    private static func run(_ editor: EditorState, window: NSWindow?, into report: inout PerformanceReport) async {
        let cues = editor.track.cues
        let middle = cues.count / 2
        var visible: [Bool] = []

        // Idle.
        editor.perform(.pause)
        try? await Task.sleep(for: .milliseconds(500))
        report.idle = await watch(for: .seconds(3))

        // Playback, from a cue in the middle.
        editor.select(cues[middle].id)
        await rest()
        visible.append(window?.occlusionState.contains(.visible) ?? false)
        editor.perform(.togglePlay)
        try? await Task.sleep(for: .milliseconds(500))
        report.playback = await watch(for: .seconds(8))
        editor.perform(.pause)
        await rest()
        visible.append(window?.occlusionState.contains(.visible) ?? false)

        // The next cue, 30 times.
        var steps: [(model: Double, load: MainThreadLoad)] = []
        for _ in 0..<30 { steps.append(await measure { editor.perform(.nextCue) }) }
        report.selectNextCue = ActionCost(steps)

        // A cue far away, there and back.
        steps = []
        for index in [cues.count / 8, cues.count * 7 / 8, cues.count / 8, middle] {
            steps.append(await measure { editor.select(cues[index].id) })
        }
        report.jumpToFarCue = ActionCost(steps)

        // Typing 25 characters into the middle cue, then undoing them.
        let cue = cues[middle]
        steps = []
        var text = cue.text
        for character in " performance test of typing" {
            text.append(character)
            let typed = text
            steps.append(await measure { editor.setText(typed, forCue: cue.id) })
        }
        report.typeCharacter = ActionCost(steps)
        steps = []
        steps.append(await measure { editor.perform(.undo) })
        steps.append(await measure { editor.perform(.redo) })
        steps.append(await measure { editor.perform(.undo) })
        report.undo = ActionCost(steps)

        // The review sidebar: the next card, 25 times; then each filter.
        if !editor.reviewItems(in: .all).isEmpty {
            if !editor.isReviewSidebarVisible { editor.perform(.toggleReviewSidebar) }
            steps = []
            for _ in 0..<25 { steps.append(await measure { editor.perform(.nextIssue) }) }
            report.nextReviewCard = ActionCost(steps)
            steps = []
            let filters: [EditorCommand] = [.toggleIssuesPanel, .reviewFrames, .reviewGlossary, .reviewChoices, .reviewWords, .reviewScriptFindings]
            for command in filters where editor.canPerform(command) {
                steps.append(await measure { editor.perform(command) })
            }
            if editor.reviewScope != .all { steps.append(await measure { editor.perform(.showAllCues) }) }
            if !steps.isEmpty { report.switchReviewFilter = ActionCost(steps) }
        }

        visible.append(window?.occlusionState.contains(.visible) ?? false)
        // Scrolling: the cue list is the leftmost long scroll view, the review sidebar the rightmost.
        let scrollViews = longScrollViews(in: window)
        if let list = scrollViews.first { report.scrollCueList = await scroll(list) }
        if scrollViews.count > 1, let sidebar = scrollViews.last { report.scrollReview = await scroll(sidebar) }

        visible.append(window?.occlusionState.contains(.visible) ?? false)
        report.windowWasVisible = report.windowWasVisible && visible.allSatisfy(\.self)

        // Single calls.
        report.calls["reviewItems(all)"] = time { _ = editor.reviewItems(in: .all) }
        report.calls["reviewCards"] = time { _ = editor.reviewCards }
        report.calls["timelineContent"] = time { _ = editor.timelineContent }
        report.calls["cue(withID:) last cue"] = time { _ = editor.cue(withID: cues[cues.count - 1].id) }
        report.calls["glossaryMatches for every cue"] = time(repeats: 5) { for cue in cues { _ = editor.glossaryMatches(for: cue.id) } }
    }

    // MARK: Measuring

    /// The main thread's work while nothing is asked of the app but what is already going on.
    private static func watch(for duration: Duration) async -> MainThreadLoad {
        let start = MainThreadMonitor.now
        try? await Task.sleep(for: duration)
        return monitor.load(since: start)
    }

    /// Does `action`, then waits for the app to be at rest: the action's own time, and all the work it caused.
    private static func measure(_ action: () -> Void) async -> (model: Double, load: MainThreadLoad) {
        await rest()
        let start = MainThreadMonitor.now
        action()
        let model = (MainThreadMonitor.now - start) * 1000
        await rest()
        return (model, monitor.load(since: start))
    }

    /// Waits until the main thread has had nothing to do for a tenth of a second (ten seconds at most).
    private static func rest() async {
        let start = MainThreadMonitor.now
        while MainThreadMonitor.now - start < 10 {
            let from = MainThreadMonitor.now
            try? await Task.sleep(for: .milliseconds(100))
            if monitor.load(since: from).busyMs < 5 { return }
        }
    }

    private static func time(repeats: Int = 20, _ work: () -> Void) -> Double {
        let start = MainThreadMonitor.now
        for _ in 0..<repeats { work() }
        return (MainThreadMonitor.now - start) * 1000 / Double(repeats)
    }

    /// Scrolls down (and back up at the end) 40 points a step, 60 steps a second asked for, for 4 seconds.
    private static func scroll(_ scrollView: NSScrollView) async -> PerformanceReport.Scroll {
        let clip = scrollView.contentView
        let limit = max((scrollView.documentView?.frame.height ?? 0) - clip.bounds.height, 0)
        var offset = 0.0
        var direction = 1.0
        clip.scroll(to: NSPoint(x: 0, y: 0))
        scrollView.reflectScrolledClipView(clip)
        await rest()
        let start = MainThreadMonitor.now
        var count = 0
        while MainThreadMonitor.now - start < 4 {
            offset += 40 * direction
            if offset >= limit || offset <= 0 { direction = -direction }
            offset = min(max(offset, 0), limit)
            clip.scroll(to: NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(clip)
            count += 1
            try? await Task.sleep(for: .milliseconds(16))
        }
        let load = monitor.load(since: start)
        return PerformanceReport.Scroll(load: load, stepsPerSecond: Double(count) / load.seconds)
    }

    /// The window's scroll views with more to show than fits, left to right.
    private static func longScrollViews(in window: NSWindow?) -> [NSScrollView] {
        var found: [NSScrollView] = []
        func visit(_ view: NSView) {
            if let scrollView = view as? NSScrollView, let document = scrollView.documentView,
               document.frame.height > scrollView.frame.height + 200 {
                found.append(scrollView)
            }
            view.subviews.forEach(visit)
        }
        if let content = window?.contentView { visit(content) }
        return found.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    /// When the process started, in seconds since the Mac started (the clock `MainThreadMonitor.now` reads).
    private static var processStart: Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0 else { return nil }
        let started = info.kp_proc.p_starttime
        let startedAt = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        let age = Date().timeIntervalSince1970 - startedAt
        return age >= 0 ? MainThreadMonitor.now - age : nil
    }
}
