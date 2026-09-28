import Foundation

/// A band-pass filter for the range most speech energy sits in, about
/// 150 Hz to 4 kHz: two high-pass and two low-pass biquads (24 dB per octave
/// on each side), as in the Audio EQ Cookbook by Robert Bristow-Johnson.
struct VoiceBandFilter {
    static let lowCut = 150.0
    static let highCut = 4_000.0

    private var stages: [Biquad]

    init(sampleRate: Double) {
        // Keep the upper edge below Nyquist for low sample rates.
        let high = min(Self.highCut, sampleRate * 0.45)
        stages = [
            .highPass(frequency: Self.lowCut, sampleRate: sampleRate),
            .highPass(frequency: Self.lowCut, sampleRate: sampleRate),
            .lowPass(frequency: high, sampleRate: sampleRate),
            .lowPass(frequency: high, sampleRate: sampleRate),
        ]
    }

    /// Filters the next samples; state carries over between calls.
    mutating func process(_ samples: [Float]) -> [Float] {
        var output = samples
        for index in stages.indices {
            stages[index].process(&output)
        }
        return output
    }
}

private struct Biquad {
    let b0, b1, b2, a1, a2: Double
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    /// Butterworth quality factor, flat in the pass band.
    static let q = 1 / 2.0.squareRoot()

    static func highPass(frequency: Double, sampleRate: Double) -> Biquad {
        let (cosine, alpha) = coefficients(frequency, sampleRate)
        let a0 = 1 + alpha
        return Biquad(
            b0: (1 + cosine) / 2 / a0, b1: -(1 + cosine) / a0, b2: (1 + cosine) / 2 / a0,
            a1: -2 * cosine / a0, a2: (1 - alpha) / a0
        )
    }

    static func lowPass(frequency: Double, sampleRate: Double) -> Biquad {
        let (cosine, alpha) = coefficients(frequency, sampleRate)
        let a0 = 1 + alpha
        return Biquad(
            b0: (1 - cosine) / 2 / a0, b1: (1 - cosine) / a0, b2: (1 - cosine) / 2 / a0,
            a1: -2 * cosine / a0, a2: (1 - alpha) / a0
        )
    }

    private static func coefficients(_ frequency: Double, _ sampleRate: Double) -> (cosine: Double, alpha: Double) {
        let omega = 2 * Double.pi * frequency / sampleRate
        return (cos(omega), sin(omega) / (2 * q))
    }

    mutating func process(_ samples: inout [Float]) {
        for index in samples.indices {
            let x0 = Double(samples[index])
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
            samples[index] = Float(y0)
        }
    }
}
