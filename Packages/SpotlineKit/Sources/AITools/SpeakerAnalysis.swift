import Accelerate
import Foundation
import MediaAnalysis
import SubtitleCore

/// Who speaks each cue, found on-device from the voice alone: a pitch and
/// timbre (MFCC) fingerprint per cue, grouped by similarity into speakers
/// (diarization), and each speaker's gender guessed from their typical pitch.
///
/// It is a light model: dependable for a handful of clearly different voices,
/// unsure when voices are alike or mixed with music. Every guess carries a
/// confidence, so only unsure lines are flagged (docs/ARCHITECTURE.md, 7b).
public struct VoiceSpeakerAnalyzer: Sendable {
    /// Voices closer than this (see `distance`) are the same speaker.
    public var sameSpeakerDistance = 1.1
    /// At most this much of each cue is analyzed.
    public var maxSecondsPerCue = 6.0

    public init() {}

    public struct Result: Sendable, Equatable {
        public var speakers: [Speaker]
        /// Each cue's speaker and how sure the grouping is (0 to 1).
        public var assignments: [Cue.ID: Assignment]
    }

    public struct Assignment: Sendable, Equatable {
        public var speakerID: Speaker.ID
        public var confidence: Double
    }

    /// A cue's voice: timbre (12 MFCCs), typical pitch and how much voiced audio it had.
    struct Voiceprint: Equatable {
        var timbre: [Float]
        /// Median fundamental frequency in Hz, nil when nothing was voiced.
        var pitch: Float?
        var voicedSeconds: Double
    }

    public func analyze(_ cues: [Cue], in audio: PreparedAudio) -> Result {
        let prints = cues.map { cue -> Voiceprint in
            let end = min(cue.end, cue.start + MediaTime(value: Int64(maxSecondsPerCue * 1000), timescale: 1000))
            return Self.voiceprint(audio.samples(from: cue.start, to: end), sampleRate: PreparedAudio.sampleRate)
        }
        return group(cues: cues, prints: prints)
    }

    /// Clusters cues by voice (average linkage), then assigns cues with too
    /// little voiced audio to the nearest speaker with a low confidence.
    func group(cues: [Cue], prints: [Voiceprint]) -> Result {
        let reliable = prints.indices.filter { prints[$0].voicedSeconds >= 0.3 && prints[$0].pitch != nil }
        var clusters: [[Int]] = reliable.map { [$0] }
        while clusters.count > 1 {
            var best: (Int, Int, Double)?
            for a in clusters.indices {
                for b in clusters.indices where b > a {
                    let d = averageDistance(clusters[a], clusters[b], prints)
                    if d < (best?.2 ?? .infinity) { best = (a, b, d) }
                }
            }
            guard let (a, b, d) = best, d < sameSpeakerDistance else { break }
            clusters[a] += clusters[b]
            clusters.remove(at: b)
        }
        // Speakers in order of their first line.
        clusters.sort { ($0.min() ?? 0) < ($1.min() ?? 0) }
        let speakers = clusters.map { members in Self.speaker(from: members.map { prints[$0] }) }
        var assignments: [Cue.ID: Assignment] = [:]
        for (clusterIndex, members) in clusters.enumerated() {
            for member in members {
                // Sure when the cue sits well inside its group and far from the others.
                let own = members.count > 1 ? averageDistance([member], members.filter { $0 != member }, prints) : 0
                let other = clusters.indices.filter { $0 != clusterIndex }
                    .map { averageDistance([member], clusters[$0], prints) }.min() ?? sameSpeakerDistance * 2
                let separation = min(max((other - own) / sameSpeakerDistance, 0), 1)
                let amount = min(prints[member].voicedSeconds / 1.5, 1)
                assignments[cues[member].id] = Assignment(speakerID: speakers[clusterIndex].id, confidence: 0.5 + 0.5 * separation * amount)
            }
        }
        for index in prints.indices where assignments[cues[index].id] == nil && prints[index].voicedSeconds > 0 {
            guard let nearest = clusters.indices.min(by: {
                averageDistance([index], clusters[$0], prints) < averageDistance([index], clusters[$1], prints)
            }) else { continue }
            assignments[cues[index].id] = Assignment(speakerID: speakers[nearest].id, confidence: 0.3)
        }
        return Result(speakers: speakers, assignments: assignments)
    }

    private func averageDistance(_ a: [Int], _ b: [Int], _ prints: [Voiceprint]) -> Double {
        var total = 0.0
        for i in a { for j in b { total += Self.distance(prints[i], prints[j]) } }
        return total / Double(max(a.count * b.count, 1))
    }

    /// Timbre distance (MFCCs, per coefficient) plus pitch distance in octaves, weighted
    /// so a speaker's pitch range (about half an octave) stays inside one speaker.
    static func distance(_ a: Voiceprint, _ b: Voiceprint) -> Double {
        var timbre: Float = 0
        for index in 0..<min(a.timbre.count, b.timbre.count) {
            let d = a.timbre[index] - b.timbre[index]
            timbre += d * d
        }
        let timbreDistance = Double((timbre / Float(max(a.timbre.count, 1))).squareRoot()) / 4
        guard let pa = a.pitch, let pb = b.pitch else { return timbreDistance + 1 }
        let octaves = abs(log2(Double(pa) / Double(pb)))
        return timbreDistance + 2.5 * octaves
    }

    /// A speaker with a gender guessed from their median pitch: under about
    /// 145 Hz is typically a man's voice, over about 185 Hz a woman's.
    static func speaker(from prints: [Voiceprint]) -> Speaker {
        let pitches = prints.compactMap(\.pitch).sorted()
        let seconds = prints.reduce(0) { $0 + $1.voicedSeconds }
        guard !pitches.isEmpty else { return Speaker(gender: .unknown, confidence: 0) }
        let median = Double(pitches[pitches.count / 2])
        let female = 1 / (1 + exp(-(median - 165) / 12))
        let certainty = max(female, 1 - female) * min(0.6 + seconds / 10, 1)
        let gender: Gender = abs(female - 0.5) < 0.1 ? .unknown : female > 0.5 ? .female : .male
        return Speaker(gender: gender, confidence: (certainty * 100).rounded() / 100, source: .inferred)
    }

    // MARK: Signal processing

    static let frameLength = 512
    static let hop = 256
    static let fftLength = 1024
    static let melBands = 24
    static let coefficients = 12

    /// Pitch and timbre over the voiced 32 ms frames of `samples`.
    static func voiceprint(_ samples: [Float], sampleRate: Int) -> Voiceprint {
        guard samples.count >= frameLength else { return Voiceprint(timbre: [], pitch: nil, voicedSeconds: 0) }
        let analyzer = FrameAnalyzer(sampleRate: sampleRate)
        let levels = stride(from: 0, to: samples.count - frameLength, by: hop).map { start -> Float in
            var sum: Float = 0
            vDSP_svesq(Array(samples[start..<start + frameLength]), 1, &sum, vDSP_Length(frameLength))
            return sum / Float(frameLength)
        }
        let loudest = levels.max() ?? 0
        var pitches: [Float] = []
        var mfccSum = [Float](repeating: 0, count: coefficients)
        var voicedFrames = 0
        for (index, level) in levels.enumerated() where level > loudest * 0.05 && level > 1e-6 {
            let start = index * hop
            let frame = analyzer.analyze(Array(samples[start..<start + frameLength]))
            guard let pitch = frame.pitch else { continue }
            pitches.append(pitch)
            vDSP_vadd(mfccSum, 1, frame.mfcc, 1, &mfccSum, 1, vDSP_Length(coefficients))
            voicedFrames += 1
        }
        guard voicedFrames > 0 else { return Voiceprint(timbre: [], pitch: nil, voicedSeconds: 0) }
        pitches.sort()
        return Voiceprint(
            timbre: mfccSum.map { $0 / Float(voicedFrames) },
            pitch: pitches[pitches.count / 2],
            voicedSeconds: Double(voicedFrames * hop) / Double(sampleRate)
        )
    }

    /// FFT-based analysis of one frame: pitch by autocorrelation (the inverse
    /// transform of the power spectrum) and MFCCs from mel band energies.
    final class FrameAnalyzer {
        let sampleRate: Int
        private let setup: FFTSetup
        private let log2n = vDSP_Length(10)
        private let window: [Float]
        private let melFilters: [[Float]]

        init(sampleRate: Int) {
            self.sampleRate = sampleRate
            setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
            window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frameLength, isHalfWindow: false)
            melFilters = Self.melFilterBank(bands: melBands, bins: fftLength / 2, sampleRate: sampleRate)
        }

        deinit { vDSP_destroy_fftsetup(setup) }

        struct Frame {
            var pitch: Float?
            var mfcc: [Float]
        }

        func analyze(_ samples: [Float]) -> Frame {
            let half = fftLength / 2
            var padded = [Float](repeating: 0, count: fftLength)
            vDSP_vmul(samples, 1, window, 1, &padded, 1, vDSP_Length(frameLength))
            var real = [Float](repeating: 0, count: half)
            var imaginary = [Float](repeating: 0, count: half)
            var power = [Float](repeating: 0, count: half)
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                    padded.withUnsafeBufferPointer { input in
                        input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                    // Nyquist is packed into the first imaginary value; drop it from bin 0.
                    power[0] = split.realp[0] * split.realp[0]
                }
            }
            return Frame(pitch: pitch(fromPower: power), mfcc: mfcc(fromPower: power))
        }

        /// The strongest autocorrelation peak between 60 and 400 Hz, when the frame is periodic enough.
        private func pitch(fromPower power: [Float]) -> Float? {
            let half = fftLength / 2
            var real = power
            var imaginary = [Float](repeating: 0, count: half)
            var autocorrelation = [Float](repeating: 0, count: fftLength)
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                    autocorrelation.withUnsafeMutableBufferPointer { output in
                        output.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
                        }
                    }
                }
            }
            guard let zero = autocorrelation.first, zero > 0 else { return nil }
            let minLag = sampleRate / 400, maxLag = min(sampleRate / 60, frameLength - 1)
            var bestLag = 0
            var best: Float = 0
            for lag in minLag...maxLag {
                // Correct for the window's shrinking overlap at longer lags.
                let value = autocorrelation[lag] / zero * Float(frameLength) / Float(frameLength - lag)
                if value > best {
                    best = value
                    bestLag = lag
                }
            }
            guard best > 0.45, bestLag > 0 else { return nil }
            // Prefer the fundamental over a subharmonic (octave errors).
            var lag = bestLag
            while lag / 2 >= minLag, autocorrelation[lag / 2] / zero * Float(frameLength) / Float(frameLength - lag / 2) > best * 0.85 {
                lag /= 2
            }
            return Float(sampleRate) / Float(lag)
        }

        private func mfcc(fromPower power: [Float]) -> [Float] {
            let energies = melFilters.map { filter -> Float in
                var sum: Float = 0
                vDSP_dotpr(filter, 1, power, 1, &sum, vDSP_Length(power.count))
                return log(max(sum, 1e-10))
            }
            // DCT-II, dropping coefficient 0 (overall loudness).
            let bands = Float(energies.count)
            return (1...coefficients).map { k in
                var sum: Float = 0
                for (n, energy) in energies.enumerated() {
                    sum += energy * cos(Float.pi * Float(k) * (Float(n) + 0.5) / bands)
                }
                return sum
            }
        }

        /// Triangular filters evenly spaced on the mel scale from 100 Hz to 7 kHz.
        static func melFilterBank(bands: Int, bins: Int, sampleRate: Int) -> [[Float]] {
            func mel(_ hz: Double) -> Double { 2595 * log10(1 + hz / 700) }
            func hz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2595) - 1) }
            let low = mel(100), high = mel(min(7000, Double(sampleRate) / 2))
            let edges = (0...(bands + 1)).map { hz(low + (high - low) * Double($0) / Double(bands + 1)) }
            let binHz = Double(sampleRate) / Double(bins * 2)
            return (0..<bands).map { band in
                (0..<bins).map { bin in
                    let f = Double(bin) * binHz
                    let (left, center, right) = (edges[band], edges[band + 1], edges[band + 2])
                    if f <= left || f >= right { return 0 }
                    return Float(f <= center ? (f - left) / (center - left) : (right - f) / (right - center))
                }
            }
        }
    }
}
