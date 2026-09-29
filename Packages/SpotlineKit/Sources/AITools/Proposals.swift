import Foundation
import SubtitleCore

/// Turns provider results into proposed changes. Kept apart from the providers
/// so the same review rules apply whichever model did the work.
public enum Proposals {
    /// New cues from a transcription. Cues that would overlap an existing cue
    /// are left out, so transcribing again only fills the gaps.
    public static func transcription(
        _ cues: [Cue], existing: [Cue], speakers: VoiceSpeakerAnalyzer.Result? = nil
    ) -> ProposedChangeSet {
        let bottom = existing.filter { $0.position == .bottom }
        let changes: [ProposedChange] = cues.compactMap { cue in
            guard !bottom.contains(where: { $0.start < cue.end && cue.start < $0.end }) else { return nil }
            var cue = cue
            cue.speakerID = speakers?.assignments[cue.id]?.speakerID
            return ProposedChange(kind: .insert, cue: cue)
        }
        return ProposedChangeSet(title: "Transcription", changes: changes, newSpeakers: speakers?.speakers ?? [])
    }

    /// Speakers and addressees for existing cues. Tags the user confirmed are kept.
    public static func speakers(
        for cues: [Cue], track: SubtitleTrack, result: VoiceSpeakerAnalyzer.Result, addressees: [Cue.ID: AddresseeTag]
    ) -> ProposedChangeSet {
        // A speaker the track already has keeps its identity (and a confirmed gender).
        let changes: [ProposedChange] = cues.compactMap { cue in
            var after = cue
            if let assignment = result.assignments[cue.id] { after.speakerID = assignment.speakerID }
            if cue.addressee?.source != .confirmed { after.addressee = addressees[cue.id] ?? cue.addressee }
            return ProposedChange.update(from: cue, to: after, note: note(for: after.addressee))
        }
        let known = Set(track.speakers.map(\.id))
        return ProposedChangeSet(
            title: "Speakers and Addressees", changes: changes, newSpeakers: result.speakers.filter { !known.contains($0.id) }
        )
    }

    /// Translated text, with the addressee and variants when the translator gave them.
    public static func translation(_ translations: [CueTranslation], cues: [Cue], title: String = "Translation") -> ProposedChangeSet {
        let byID = Dictionary(cues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let changes: [ProposedChange] = translations.compactMap { translation in
            guard let cue = byID[translation.cueID] else { return nil }
            var after = cue
            after.text = translation.text
            if cue.addressee?.source == .confirmed {
                // The user said who is addressed: use that variant when there is one.
                if let chosen = translation.variants?.first(where: { $0.addressee == cue.addressee?.addressee }) {
                    after.text = chosen.text
                }
                after.variants = translation.variants
            } else {
                if let tag = translation.addressee { after.addressee = tag }
                after.variants = translation.variants
            }
            return ProposedChange.update(from: cue, to: after, note: note(for: after.addressee))
        }
        return ProposedChangeSet(title: title, changes: changes)
    }

    static func note(for tag: AddresseeTag?) -> String? {
        guard let tag, tag.needsReview else { return nil }
        return "Unsure who is addressed (\(Int((tag.confidence * 100).rounded()))%)"
    }
}
