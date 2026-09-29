/// chrF (Popović, 2015): the F-score of character n-grams (1 to 6, recall
/// weighted twice as much as precision), averaged over n, whitespace ignored.
///
/// Chosen for translation quality because it needs no tokenizer or model,
/// handles Arabic's rich morphology better than word-level BLEU (a different
/// prefix or suffix costs a few n-grams, not the whole word), and agrees with
/// human judgments better than BLEU in WMT metric studies. Statistics add up
/// over segments, so the corpus score is computed as sacreBLEU's `chrF` does.
public enum ChrF {
    public static let order = 6
    public static let beta = 2.0

    /// Per n: n-grams in the hypothesis, in the reference, and shared.
    public struct Statistics: Codable, Sendable, Equatable {
        public var hypothesis: [Int]
        public var reference: [Int]
        public var matches: [Int]

        public init() {
            hypothesis = Array(repeating: 0, count: ChrF.order)
            reference = Array(repeating: 0, count: ChrF.order)
            matches = Array(repeating: 0, count: ChrF.order)
        }

        /// 0 to 100.
        public var score: Double {
            let factor = ChrF.beta * ChrF.beta
            var total = 0.0
            var orders = 0
            for n in 0..<ChrF.order {
                let precision = hypothesis[n] > 0 ? Double(matches[n]) / Double(hypothesis[n]) : 1e-16
                let recall = reference[n] > 0 ? Double(matches[n]) / Double(reference[n]) : 1e-16
                let denominator = factor * precision + recall
                total += denominator > 0 ? (1 + factor) * precision * recall / denominator : 1e-16
                if hypothesis[n] > 0, reference[n] > 0 { orders += 1 }
            }
            return orders == 0 ? 0 : 100 * total / Double(orders)
        }

        public static func + (lhs: Self, rhs: Self) -> Self {
            var sum = Self()
            for n in 0..<ChrF.order {
                sum.hypothesis[n] = lhs.hypothesis[n] + rhs.hypothesis[n]
                sum.reference[n] = lhs.reference[n] + rhs.reference[n]
                sum.matches[n] = lhs.matches[n] + rhs.matches[n]
            }
            return sum
        }
    }

    public static func statistics(hypothesis: String, reference: String) -> Statistics {
        let hyp = Array(hypothesis.filter { !$0.isWhitespace })
        let ref = Array(reference.filter { !$0.isWhitespace })
        var result = Statistics()
        for n in 1...order {
            let hypGrams = grams(hyp, n), refGrams = grams(ref, n)
            result.hypothesis[n - 1] = hypGrams.values.reduce(0, +)
            result.reference[n - 1] = refGrams.values.reduce(0, +)
            result.matches[n - 1] = hypGrams.reduce(0) { $0 + min($1.value, refGrams[$1.key] ?? 0) }
        }
        return result
    }

    static func grams(_ characters: [Character], _ n: Int) -> [String: Int] {
        guard characters.count >= n else { return [:] }
        var counts: [String: Int] = [:]
        for start in 0...(characters.count - n) {
            counts[String(characters[start..<(start + n)]), default: 0] += 1
        }
        return counts
    }
}
