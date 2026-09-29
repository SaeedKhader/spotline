import Foundation

/// A benchmark run: scores per sample, what was run, and a Markdown rendering
/// that can put another run beside it (before and after a change).
public struct BenchmarkReport: Codable, Sendable {
    public struct Sample: Codable, Sendable {
        public var name: String
        public var transcription: TranscriptionScore?
        public var translation: TranslationScore?
        /// Anything skipped or odd ("no Arabic reference").
        public var notes: [String]

        public init(name: String, transcription: TranscriptionScore? = nil, translation: TranslationScore? = nil, notes: [String] = []) {
            self.name = name
            self.transcription = transcription
            self.translation = translation
            self.notes = notes
        }
    }

    /// "baseline", "fix-up: timing"…
    public var label: String
    public var date: Date
    /// "Apple Speech", "Apple Translation", "Netflix (Adult)"…
    public var settings: [String: String]
    public var samples: [Sample]

    public init(label: String, date: Date = Date(), settings: [String: String] = [:], samples: [Sample] = []) {
        self.label = label
        self.date = date
        self.settings = settings
        self.samples = samples
    }

    public var transcription: TranscriptionScore? {
        let scores = samples.compactMap(\.transcription)
        return scores.isEmpty ? nil : scores.dropFirst().reduce(scores[0], +)
    }

    public var translation: TranslationScore? {
        let scores = samples.compactMap(\.translation)
        return scores.isEmpty ? nil : scores.dropFirst().reduce(scores[0], +)
    }

    // MARK: Markdown

    /// A metric: its name, how to read it, and its value in a report.
    struct Metric: Sendable {
        var name: String
        /// True when a higher value is better.
        var higherIsBetter: Bool
        var format: @Sendable (Double) -> String
        var value: @Sendable (BenchmarkReport) -> Double?
        /// Signed values (a mean offset) are better nearer zero.
        var signed = false
    }

    public static let percent: @Sendable (Double) -> String = { String(format: "%.1f%%", $0 * 100) }
    static let milliseconds: @Sendable (Double) -> String = { String(format: "%.0f ms", $0 * 1000) }
    static let signedMilliseconds: @Sendable (Double) -> String = { String(format: "%+.0f ms", $0 * 1000) }
    public static let plain: @Sendable (Double) -> String = { String(format: "%.1f", $0) }

    static let transcriptionMetrics: [Metric] = [
        Metric(name: "Word error rate", higherIsBetter: false, format: percent) { $0.transcription?.wordErrorRate },
        Metric(name: "Start drift, median", higherIsBetter: false, format: milliseconds) { $0.transcription?.startOffsets.medianAbsolute },
        Metric(name: "Start drift, 90th percentile", higherIsBetter: false, format: milliseconds) { $0.transcription?.startOffsets.p90Absolute },
        Metric(name: "Start drift, mean (+ late)", higherIsBetter: false, format: signedMilliseconds, value: { $0.transcription?.startOffsets.mean }, signed: true),
        Metric(name: "Starts within 100 ms", higherIsBetter: true, format: percent) { $0.transcription?.startOffsets.within(0.1) },
        Metric(name: "End drift, median", higherIsBetter: false, format: milliseconds) { $0.transcription?.endOffsets.medianAbsolute },
        Metric(name: "End drift, mean (+ late)", higherIsBetter: false, format: signedMilliseconds, value: { $0.transcription?.endOffsets.mean }, signed: true),
        Metric(name: "Ends within 250 ms", higherIsBetter: true, format: percent) { $0.transcription?.endOffsets.within(0.25) },
        Metric(name: "Cue splits, F1", higherIsBetter: true, format: percent) { $0.transcription?.boundaryF1 },
        Metric(name: "Line breaks as reference", higherIsBetter: true, format: percent) { $0.transcription?.lineBreakAgreement },
        Metric(name: "Rule breaks per cue", higherIsBetter: false, format: percent) { $0.transcription?.rules.breakingShare },
        Metric(name: "Cues off a nearby shot change", higherIsBetter: false, format: percent) { report in
            report.transcription.map { $0.rules.cues == 0 ? 0 : Double($0.rules.offShotChange) / Double($0.rules.cues) }
        },
    ]

    static let translationMetrics: [Metric] = [
        Metric(name: "chrF", higherIsBetter: true, format: plain) { $0.translation?.chrF.score },
        Metric(name: "Addressee form agreement", higherIsBetter: true, format: percent) { $0.translation?.addresseeAccuracy },
        Metric(name: "Glossary terms used", higherIsBetter: true, format: percent) { $0.translation?.glossaryUse },
        Metric(name: "Rule breaks per cue", higherIsBetter: false, format: percent) { $0.translation?.rules.breakingShare },
        Metric(name: "Lines over the limit", higherIsBetter: false, format: percent) { report in
            report.translation.map { $0.rules.lines == 0 ? 0 : Double($0.rules.linesTooLong) / Double($0.rules.lines) }
        },
    ]

    /// The report as Markdown; with `baseline`, each metric shows both runs and the change.
    public func markdown(comparedTo baseline: BenchmarkReport? = nil) -> String {
        var out = "# Spotline AI benchmark: \(label)\n\n"
        let date = ISO8601DateFormatter.string(from: self.date, timeZone: .current, formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime])
        out += "\(date). " + settings.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + ".\n\n"
        if let baseline { out += "Compared with **\(baseline.label)** (\(baseline.samples.count) samples).\n\n" }
        for (title, metrics, has) in [
            ("Transcription", Self.transcriptionMetrics, transcription != nil),
            ("Translation", Self.translationMetrics, translation != nil),
        ] where has {
            out += "## \(title)\n\n"
            out += baseline == nil ? "| Metric | Value |\n|---|---|\n" : "| Metric | \(baseline!.label) | \(label) | Change |\n|---|---|---|---|\n"
            for metric in metrics {
                let now = metric.value(self)
                if let baseline {
                    let before = metric.value(baseline)
                    out += "| \(metric.name) | \(before.map(metric.format) ?? "–") | \(now.map(metric.format) ?? "–") | \(Self.change(before, now, metric)) |\n"
                } else {
                    out += "| \(metric.name) | \(now.map(metric.format) ?? "–") |\n"
                }
            }
            out += "\n"
        }
        if let score = transcription {
            out += "Words: \(score.referenceWords) in the reference; \(score.substitutions) substituted, \(score.deletions) missed, \(score.insertions) added. "
            out += "Timing compares \(score.startOffsets.count) starts and \(score.endOffsets.count) ends that fall on the same word in both. "
            out += "Rule breaks: \(Self.rules(score.rules)); the reference itself has \(Self.rules(score.referenceRules)).\n\n"
        }
        if let score = translation {
            out += "Translation: \(score.segments) lines, translated from the reference source text and compared with the reference translation (chrF on normalized text, 0 to 100). "
            out += "Addressee agreement covers \(score.addresseeLines) lines where either side uses a marked Arabic \"you\" (feminine or plural). "
            out += "Rule breaks: \(Self.rules(score.rules)); the reference itself has \(Self.rules(score.referenceRules)).\n\n"
        }
        out += "## Samples\n\n| Sample | WER | Start drift | Cue split F1 | chrF | Addressee | Notes |\n|---|---|---|---|---|---|---|\n"
        for sample in samples {
            let t = sample.transcription, x = sample.translation
            out += "| \(sample.name) | \(t.map { Self.percent($0.wordErrorRate) } ?? "–") "
            out += "| \(t?.startOffsets.medianAbsolute.map(Self.milliseconds) ?? "–") | \(t.map { Self.percent($0.boundaryF1) } ?? "–") "
            out += "| \(x.map { Self.plain($0.chrF.score) } ?? "–") | \(x?.addresseeAccuracy.map(Self.percent) ?? "–") "
            out += "| \(sample.notes.joined(separator: "; ")) |\n"
        }
        return out
    }

    static func change(_ before: Double?, _ after: Double?, _ metric: Metric) -> String {
        guard var before, var after else { return "" }
        if metric.signed {
            before = abs(before)
            after = abs(after)
        }
        let delta = after - before
        guard abs(delta) > 1e-9 else { return "same" }
        let better = (delta > 0) == metric.higherIsBetter
        var formatted = metric.format(abs(delta))
        if formatted.hasPrefix("+") { formatted.removeFirst() }
        return "\(delta > 0 ? "+" : "−")\(formatted) \(better ? "better" : "worse")"
    }

    static func rules(_ counts: RuleCounts) -> String {
        "\(counts.cues) cues, \(counts.linesTooLong) long lines, \(counts.tooManyLines) with too many lines, "
            + "\(counts.readingSpeedTooFast) too fast to read, \(counts.tooShort) too short, \(counts.tooLong) too long, "
            + "\(counts.gapTooShort) gaps too short, \(counts.overlaps) overlaps, \(counts.offShotChange) off a shot change"
    }
}
