import Foundation
import MediaAnalysis
import SubtitleCore

/// Leaves out walla: crowd chatter mixed under the main dialogue, which
/// professional subtitles do not subtitle. Scribe transcribes it like any other
/// voice, and has no setting against it.
///
/// A stretch of one voice (its words with pauses under `pauseSeconds`) goes when
/// its loudest moment is `quieterBy` dB under the dialogue around it (the median
/// loudest moment of the other stretches within `windowSeconds`), or
/// `briefVoiceQuieterBy` dB for a voice heard for under `briefVoiceSeconds` in all.
///
/// Measured on five episodes of A Knight of the Seven Kingdoms against their
/// professional subtitles: 18 dB left out crowd lines and very little the
/// subtitlers kept; quieter thresholds took whispers and trailing words with them.
/// Sound descriptions are left alone.
public struct WallaFilter: Sendable {
    public var levels: SpeechLevels
    public var quieterBy: Float = 18
    public var briefVoiceQuieterBy: Float = 14
    public var briefVoiceSeconds = 20.0
    public var windowSeconds = 60.0
    public var pauseSeconds = 1.5
    /// Fewer stretches than this around a line say nothing about the scene's dialogue.
    public var minimumNeighbours = 3

    public init(levels: SpeechLevels) {
        self.levels = levels
    }

    /// The words without the walla, in order. Words must be in time order.
    public func words(_ words: [TranscribedWord]) -> [TranscribedWord] {
        let dropped = wallaIndexes(words)
        guard !dropped.isEmpty else { return words }
        return words.indices.filter { !dropped.contains($0) }.map { words[$0] }
    }

    /// How far (dB) each span's loudest moment is under the dialogue around it
    /// (the median of the other spans within `windowSeconds`); nil with too little
    /// dialogue around. Spans must be in time order. For telling a translator which
    /// lines sound like walla.
    public func quieterBy(_ spans: [(start: MediaTime, end: MediaTime)]) -> [Float?] {
        let loudest = spans.map { levels.loudest(from: $0.start, to: max($0.end, $0.start + MediaTime(value: 60, timescale: 1000))) }
        return spans.indices.map { index in
            let around = spans.indices.filter { other in
                other != index && abs((spans[other].start - spans[index].start).seconds) <= windowSeconds
            }.map { loudest[$0] }.sorted()
            guard around.count >= minimumNeighbours else { return nil }
            return around[around.count / 2] - loudest[index]
        }
    }

    struct Stretch {
        var speaker: String?
        var indexes: [Int]
        var start: MediaTime
        var end: MediaTime
        var loudest: Float
    }

    func wallaIndexes(_ words: [TranscribedWord]) -> Set<Int> {
        var stretches: [Stretch] = []
        var spoken: [String: Double] = [:]
        let pause = MediaTime(value: Int64((pauseSeconds * 1000).rounded()), timescale: 1000)
        // A word Scribe gave no length is measured over at least 60 ms.
        let shortest = MediaTime(value: 60, timescale: 1000)
        for (index, word) in words.enumerated() where !TranscriptionPipeline.isSoundDescription(word.text) {
            let loudness = levels.loudest(from: word.start, to: max(word.end, word.start + shortest))
            if let speaker = word.speaker { spoken[speaker, default: 0] += (word.end - word.start).seconds }
            if var last = stretches.last, last.speaker == word.speaker, word.start - last.end <= pause {
                last.indexes.append(index)
                last.end = max(last.end, word.end)
                last.loudest = max(last.loudest, loudness)
                stretches[stretches.count - 1] = last
            } else {
                stretches.append(Stretch(speaker: word.speaker, indexes: [index], start: word.start, end: word.end, loudest: loudness))
            }
        }
        var dropped = Set<Int>()
        for (index, stretch) in stretches.enumerated() {
            let around = stretches.indices.filter { other in
                other != index && abs((stretches[other].start - stretch.start).seconds) <= windowSeconds
            }.map { stretches[$0].loudest }.sorted()
            guard around.count >= minimumNeighbours else { continue }
            let dialogue = around[around.count / 2]
            let isBrief = stretch.speaker.map { (spoken[$0] ?? 0) < briefVoiceSeconds } ?? false
            if stretch.loudest < dialogue - (isBrief ? briefVoiceQuieterBy : quieterBy) { dropped.formUnion(stretch.indexes) }
        }
        return dropped
    }
}
