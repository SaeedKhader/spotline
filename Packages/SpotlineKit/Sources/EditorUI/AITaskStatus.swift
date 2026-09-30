import AITools
import Foundation
import SubtitleCore

/// A running AI tool, in the words the AI bar shows: its stages, the one it is
/// in, what is happening now and, only where something measures it, how far it
/// has got. A stage nothing measures (the provider working on the whole file)
/// shows how long it has been waiting instead of a made-up percentage.
public struct AITaskStatus: Equatable, Sendable {
    /// "Transcription", "Translation".
    public var title: String
    /// The provider's name without where it runs: "ElevenLabs Scribe", "Claude".
    public var provider: String
    /// The steps in order: "Preparing audio", "Uploading", "Transcribing", "Building cues".
    public var stages: [String]
    public var stage = 0
    /// What is happening now: "Uploading 6.1 of 18 MB", "Claude · 120 of 640 lines".
    public var detail: String
    /// How far the stage has got, 0 to 1; nil when nothing measures it.
    public var fraction: Double?
    /// Since when the provider has been working with nothing to measure it by.
    public var waitingSince: Date?
    /// The cues of the lines being translated now.
    public var inFlight: Set<Cue.ID> = []
    /// When the lines should all be done, from the rate measured over the batches
    /// after the first (which is smaller, and pays for reading the script). Nil until then.
    public var estimatedEnd: Date?
    /// Lines done and when, at the end of the first batch: where the rate is measured from.
    var rateStart: (lines: Int, at: Date)?

    public init(title: String, provider: String, stages: [String], detail: String? = nil) {
        self.title = title
        self.provider = Self.shortName(provider)
        self.stages = stages
        self.detail = detail ?? stages.first ?? title
    }

    public static func == (lhs: AITaskStatus, rhs: AITaskStatus) -> Bool {
        lhs.title == rhs.title && lhs.provider == rhs.provider && lhs.stages == rhs.stages && lhs.stage == rhs.stage
            && lhs.detail == rhs.detail && lhs.fraction == rhs.fraction && lhs.waitingSince == rhs.waitingSince
            && lhs.inFlight == rhs.inFlight && lhs.estimatedEnd == rhs.estimatedEnd
    }

    /// "Claude (cloud)" → "Claude"; "Apple Speech (on this Mac)" → "Apple Speech".
    static func shortName(_ name: String) -> String {
        name.replacing(/\s*\([^)]*\)$/, with: "")
    }

    /// How far the whole task has got, for the Dock: finished stages, plus the
    /// measured part of this one (none while nothing measures it).
    public var overallFraction: Double {
        guard !stages.isEmpty else { return 0 }
        return (Double(stage) + (fraction ?? 0)) / Double(stages.count)
    }

    /// Moves to the stage named `name` (a stage that isn't listed leaves it where it is).
    mutating func enter(_ name: String, detail: String? = nil, fraction: Double? = nil) {
        if let index = stages.firstIndex(of: name), index != stage {
            stage = index
            waitingSince = nil
        }
        self.detail = detail ?? name
        self.fraction = fraction
    }

    /// Takes in a provider's report. `now` is when it arrived.
    mutating func update(with progress: AIProgress, now: Date) {
        switch progress {
        case .fraction(let value):
            enter(title == "Translation" ? "Translating" : "Transcribing", detail: "\(provider) · \(Self.percent(value))", fraction: value)
        case .encoding:
            enter("Uploading", detail: "Compressing audio")
        case .uploading(let sent, let total):
            let value = total > 0 ? Double(sent) / Double(total) : nil
            enter("Uploading", detail: "Uploading \(Self.megabytes(sent, of: total))", fraction: value)
        case .waiting:
            enter("Transcribing", detail: "\(provider) is transcribing")
            if waitingSince == nil { waitingSince = now }
        case .parts(let done, let total):
            enter("Transcribing", detail: "\(provider) · \(done) of \(total) parts", fraction: total > 0 ? Double(done) / Double(total) : nil)
        case .lines(let done, let total, let lines):
            enter("Translating", detail: "\(provider) · \(done) of \(total) lines", fraction: total > 0 ? Double(done) / Double(total) : nil)
            inFlight = Set(lines)
            estimate(done: done, total: total, now: now)
        case .retrying(let lines):
            detail = lines.count == 1 ? "\(provider) · retrying 1 declined line" : "\(provider) · retrying \(lines.count) declined lines"
            inFlight = Set(lines)
        }
    }

    private mutating func estimate(done: Int, total: Int, now: Date) {
        guard done > 0 else { return }
        guard let start = rateStart else {
            rateStart = (done, now)
            return
        }
        let seconds = now.timeIntervalSince(start.at)
        guard done > start.lines, seconds > 0 else { return }
        let perLine = seconds / Double(done - start.lines)
        estimatedEnd = now.addingTimeInterval(perLine * Double(total - done))
    }

    /// "About 4 min left", "Under a minute left", from `end`; nil once it has passed.
    public static func timeLeft(until end: Date, now: Date) -> String? {
        let seconds = end.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        if seconds < 60 { return "under a minute left" }
        return "about \(Int((seconds / 60).rounded())) min left"
    }

    /// "1:12", "1:02:05".
    public static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(Int(now.timeIntervalSince(start)), 0)
        let (hours, minutes, rest) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    static func percent(_ value: Double) -> String {
        "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }

    /// "6.1 of 18 MB".
    static func megabytes(_ sent: Int64, of total: Int64) -> String {
        func format(_ bytes: Int64) -> String {
            let value = Double(bytes) / 1_000_000
            return value < 10 ? String(format: "%.1f", value) : String(Int(value.rounded()))
        }
        return "\(format(sent)) of \(format(total)) MB"
    }
}

/// What an AI tool did, shown in the AI bar for a few seconds after it finishes.
/// (What is left to review has its own button in the actions bar.)
public struct AITaskSummary: Equatable, Sendable {
    /// "640 lines translated".
    public var text: String
    /// What is left for the person: "12 flagged".
    public var followUp: String?

    /// "640 lines translated · 12 flagged".
    public var fullText: String {
        [text, followUp].compactMap(\.self).joined(separator: " · ")
    }
}
