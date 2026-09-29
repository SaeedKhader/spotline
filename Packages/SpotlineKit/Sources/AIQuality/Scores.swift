import QualityControl
import SubtitleCore

/// Offsets in seconds, hypothesis minus reference (positive: late).
public struct Offsets: Codable, Sendable, Equatable {
    public var values: [Double]

    public init(_ values: [Double] = []) {
        self.values = values
    }

    public var count: Int { values.count }
    public var mean: Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
    public var medianAbsolute: Double? { Self.quantile(values.map(abs), 0.5) }
    public var p90Absolute: Double? { Self.quantile(values.map(abs), 0.9) }
    /// Share within `seconds` of the reference.
    public func within(_ seconds: Double) -> Double? {
        values.isEmpty ? nil : Double(values.count { abs($0) <= seconds }) / Double(values.count)
    }

    static func quantile(_ values: [Double], _ q: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let position = q * Double(sorted.count - 1)
        let low = Int(position.rounded(.down)), high = Int(position.rounded(.up))
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }

    static func + (lhs: Offsets, rhs: Offsets) -> Offsets { Offsets(lhs.values + rhs.values) }
}

/// How many cues break each rule of a preset (QualityControl's checks).
public struct RuleCounts: Codable, Sendable, Equatable {
    public var cues = 0
    public var lines = 0
    public var linesTooLong = 0
    public var tooManyLines = 0
    public var readingSpeedTooFast = 0
    public var tooShort = 0
    public var tooLong = 0
    public var gapTooShort = 0
    public var overlaps = 0
    /// Starts or ends near a shot change but not on it.
    public var offShotChange = 0

    public init() {}

    public init(_ cues: [Cue], preset: QCPreset, context: QualityControl.Context) {
        let sorted = cues.sorted { $0.start < $1.start }
        self.cues = sorted.count
        lines = sorted.reduce(0) { $0 + SubtitleText.visibleLines(of: $1.text).count }
        for issues in QualityControl.check(sorted, preset: preset, context: context).values {
            for issue in issues {
                switch issue.kind {
                case .lineTooLong: linesTooLong += 1
                case .tooManyLines: tooManyLines += 1
                case .readingSpeed: readingSpeedTooFast += 1
                case .tooShort: tooShort += 1
                case .tooLong: tooLong += 1
                case .gapTooShort: gapTooShort += 1
                case .overlapsNext: overlaps += 1
                case .startNearShotChange, .endNearShotChange: offShotChange += 1
                default: break
                }
            }
        }
    }

    /// Cues breaking a layout or reading rule, over all cues (lines too long count per line).
    public var breakingShare: Double {
        cues == 0 ? 0 : Double(linesTooLong + tooManyLines + readingSpeedTooFast + tooShort + tooLong) / Double(cues)
    }

    static func + (lhs: RuleCounts, rhs: RuleCounts) -> RuleCounts {
        var sum = RuleCounts()
        sum.cues = lhs.cues + rhs.cues
        sum.lines = lhs.lines + rhs.lines
        sum.linesTooLong = lhs.linesTooLong + rhs.linesTooLong
        sum.tooManyLines = lhs.tooManyLines + rhs.tooManyLines
        sum.readingSpeedTooFast = lhs.readingSpeedTooFast + rhs.readingSpeedTooFast
        sum.tooShort = lhs.tooShort + rhs.tooShort
        sum.tooLong = lhs.tooLong + rhs.tooLong
        sum.gapTooShort = lhs.gapTooShort + rhs.gapTooShort
        sum.overlaps = lhs.overlaps + rhs.overlaps
        sum.offShotChange = lhs.offShotChange + rhs.offShotChange
        return sum
    }
}

/// A transcription's cues against reference subtitles in the same language.
public struct TranscriptionScore: Codable, Sendable, Equatable {
    public var referenceWords = 0
    public var substitutions = 0
    public var deletions = 0
    public var insertions = 0
    /// Cue starts and ends that fall on the same word in both, hypothesis minus reference.
    public var startOffsets = Offsets()
    public var endOffsets = Offsets()
    /// Cue starts (on words both heard) that both put a cue boundary before.
    public var sharedBoundaries = 0
    public var referenceBoundaries = 0
    public var hypothesisBoundaries = 0
    /// Cues with the same words in both, and how many of those break their lines at the same word.
    public var sameCues = 0
    public var sameLineBreaks = 0
    public var rules = RuleCounts()
    public var referenceRules = RuleCounts()

    public init() {}

    /// Word error rate: (substitutions + deletions + insertions) / reference words.
    public var wordErrorRate: Double {
        referenceWords == 0 ? 0 : Double(substitutions + deletions + insertions) / Double(referenceWords)
    }

    public var boundaryPrecision: Double { hypothesisBoundaries == 0 ? 0 : Double(sharedBoundaries) / Double(hypothesisBoundaries) }
    public var boundaryRecall: Double { referenceBoundaries == 0 ? 0 : Double(sharedBoundaries) / Double(referenceBoundaries) }
    public var boundaryF1: Double {
        let p = boundaryPrecision, r = boundaryRecall
        return p + r == 0 ? 0 : 2 * p * r / (p + r)
    }

    public var lineBreakAgreement: Double? { sameCues == 0 ? nil : Double(sameLineBreaks) / Double(sameCues) }

    public static func + (lhs: Self, rhs: Self) -> Self {
        var sum = Self()
        sum.referenceWords = lhs.referenceWords + rhs.referenceWords
        sum.substitutions = lhs.substitutions + rhs.substitutions
        sum.deletions = lhs.deletions + rhs.deletions
        sum.insertions = lhs.insertions + rhs.insertions
        sum.startOffsets = lhs.startOffsets + rhs.startOffsets
        sum.endOffsets = lhs.endOffsets + rhs.endOffsets
        sum.sharedBoundaries = lhs.sharedBoundaries + rhs.sharedBoundaries
        sum.referenceBoundaries = lhs.referenceBoundaries + rhs.referenceBoundaries
        sum.hypothesisBoundaries = lhs.hypothesisBoundaries + rhs.hypothesisBoundaries
        sum.sameCues = lhs.sameCues + rhs.sameCues
        sum.sameLineBreaks = lhs.sameLineBreaks + rhs.sameLineBreaks
        sum.rules = lhs.rules + rhs.rules
        sum.referenceRules = lhs.referenceRules + rhs.referenceRules
        return sum
    }
}

/// A translation of the reference source cues against the reference translation.
public struct TranslationScore: Codable, Sendable, Equatable {
    /// Source cues with reference text to compare against.
    public var segments = 0
    public var chrF = ChrF.Statistics()
    /// Lines whose addressee form (Arabic: feminine or plural "you") either side marks.
    public var addresseeLines = 0
    public var addresseeAgreements = 0
    /// Glossary terms in the source, and how many of those the translation used.
    public var glossaryTerms = 0
    public var glossaryTermsUsed = 0
    public var rules = RuleCounts()
    public var referenceRules = RuleCounts()

    public init() {}

    public var addresseeAccuracy: Double? { addresseeLines == 0 ? nil : Double(addresseeAgreements) / Double(addresseeLines) }
    public var glossaryUse: Double? { glossaryTerms == 0 ? nil : Double(glossaryTermsUsed) / Double(glossaryTerms) }

    public static func + (lhs: Self, rhs: Self) -> Self {
        var sum = Self()
        sum.segments = lhs.segments + rhs.segments
        sum.chrF = lhs.chrF + rhs.chrF
        sum.addresseeLines = lhs.addresseeLines + rhs.addresseeLines
        sum.addresseeAgreements = lhs.addresseeAgreements + rhs.addresseeAgreements
        sum.glossaryTerms = lhs.glossaryTerms + rhs.glossaryTerms
        sum.glossaryTermsUsed = lhs.glossaryTermsUsed + rhs.glossaryTermsUsed
        sum.rules = lhs.rules + rhs.rules
        sum.referenceRules = lhs.referenceRules + rhs.referenceRules
        return sum
    }
}
