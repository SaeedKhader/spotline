/// Clock-style timestamps with milliseconds, `HH:MM:SS,mmm`, as SRT and
/// WebVTT write them and as some editors display times.
public enum Timestamp {
    /// `HH:MM:SS<separator>mmm`, rounded to the nearest millisecond. Negative times read as zero.
    public static func format(_ time: MediaTime, fractionSeparator: Character = ",") -> String {
        let value = max(time.value, 0)
        let milliseconds = (2 * value * 1000 + time.timescale) / (2 * time.timescale)
        let fraction = milliseconds % 1000
        let totalSeconds = milliseconds / 1000
        return "\(pad(totalSeconds / 3600, 2)):\(pad(totalSeconds / 60 % 60, 2)):\(pad(totalSeconds % 60, 2))"
            + "\(fractionSeparator)\(pad(fraction, 3))"
    }

    /// Parses `[H…:]MM:SS[.,]fff` exactly. The fraction may have any number of digits.
    public static func parse<S: StringProtocol>(_ field: S) -> MediaTime? {
        let parts = field.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let secondsParts = parts[parts.count - 1].split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == "." })
        guard secondsParts.count <= 2,
              let hours = parts.count == 3 ? digits(parts[0]) : 0,
              let minutes = digits(parts[parts.count - 2]), minutes < 60,
              let seconds = digits(secondsParts[0]), seconds < 60
        else { return nil }
        var fraction: Int64 = 0
        var timescale: Int64 = 1
        if secondsParts.count == 2 {
            let fractionField = secondsParts[1]
            guard !fractionField.isEmpty, fractionField.count <= 9, let value = digits(fractionField) else { return nil }
            fraction = value
            for _ in 0..<fractionField.count { timescale *= 10 }
        }
        let wholeSeconds = (hours * 60 + minutes) * 60 + seconds
        return MediaTime(value: wholeSeconds * timescale + fraction, timescale: timescale)
    }

    private static func digits<S: StringProtocol>(_ field: S) -> Int64? {
        guard !field.isEmpty, field.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int64(field)
    }

    private static func pad(_ value: Int64, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(width - digits.count, 0)) + digits
    }
}
