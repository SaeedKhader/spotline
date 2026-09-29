import Foundation

/// Grammatical gender, as far as a language's agreement needs it.
public enum Gender: String, Hashable, Sendable, Codable, CaseIterable {
    case male
    case female
    case unknown
}

/// Where a speaker's gender or a line's addressee came from.
public enum TagSource: String, Hashable, Sendable, Codable {
    /// Guessed by a tool (voice classifier, scene reading); may be wrong.
    case inferred
    /// Confirmed by the user; tools never overwrite it.
    case confirmed
}

/// One person in the cast. Transcription finds speakers by voice (Speaker A,
/// B…); names are optional. See docs/ARCHITECTURE.md, section 7b.
public struct Speaker: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String?
    public var gender: Gender
    /// 0 to 1: how sure `source` is of `gender`.
    public var confidence: Double
    public var source: TagSource

    public init(id: UUID = UUID(), name: String? = nil, gender: Gender = .unknown, confidence: Double = 0, source: TagSource = .inferred) {
        self.id = id
        self.name = name
        self.gender = gender
        self.confidence = confidence
        self.source = source
    }
}

/// Who a line is spoken to, in the terms Arabic (and similar languages) conjugate
/// for: gender and number. "You are busy" is انتَ مشغول, انتِ مشغولة, انتما مشغولان,
/// انتم مشغولون or انتن مشغولات depending on it.
public enum Addressee: String, Hashable, Sendable, Codable, CaseIterable {
    case male
    case female
    case dualMale
    case dualFemale
    case groupMale
    case groupFemale
    case groupMixed
    case unknown

    public var gender: Gender {
        switch self {
        case .male, .dualMale, .groupMale: .male
        case .female, .dualFemale, .groupFemale: .female
        case .groupMixed, .unknown: .unknown
        }
    }

    /// One, two (Arabic has a dual) or more people.
    public var count: Count {
        switch self {
        case .male, .female: .one
        case .dualMale, .dualFemale: .two
        case .groupMale, .groupFemale, .groupMixed: .many
        case .unknown: .unknown
        }
    }

    public enum Count: String, Hashable, Sendable, Codable {
        case one, two, many, unknown
    }

    /// The chip the cue list shows once tools fill this in: ♂, ♀ or a group sign.
    public var symbol: String {
        switch self {
        case .male: "♂"
        case .female: "♀"
        case .dualMale: "♂♂"
        case .dualFemale: "♀♀"
        case .groupMale, .groupFemale, .groupMixed: "👥"
        case .unknown: "?"
        }
    }
}

/// A line's addressee with how sure the tagger was.
public struct AddresseeTag: Hashable, Sendable, Codable {
    public var addressee: Addressee
    /// 0 to 1.
    public var confidence: Double
    public var source: TagSource

    public init(_ addressee: Addressee, confidence: Double, source: TagSource = .inferred) {
        self.addressee = addressee
        self.confidence = confidence
        self.source = source
    }

    /// Below this, an inferred tag is a guess the user should review.
    public static let reviewThreshold = 0.75

    /// True for an inferred tag the tagger was unsure of, or one that could not decide.
    public var needsReview: Bool {
        source == .inferred && (confidence < Self.reviewThreshold || addressee == .unknown)
    }
}

/// A line as it reads for one addressee, e.g. انتِ مشغولة for a woman.
public struct TextVariant: Hashable, Sendable, Codable {
    public var addressee: Addressee
    public var text: String

    public init(addressee: Addressee, text: String) {
        self.addressee = addressee
        self.text = text
    }
}
