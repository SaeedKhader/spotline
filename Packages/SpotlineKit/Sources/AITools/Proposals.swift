import Foundation
import SubtitleCore

/// Turns provider results into proposed changes. Kept apart from the providers
/// so the same review rules apply whichever model did the work.
public enum Proposals {
    /// New cues from a transcription. Cues that would overlap an existing cue
    /// are left out, so transcribing again only fills the gaps.
    public static func transcription(_ cues: [Cue], existing: [Cue]) -> ProposedChangeSet {
        let bottom = existing.filter { $0.position == .bottom }
        let changes: [ProposedChange] = cues.compactMap { cue in
            guard !bottom.contains(where: { $0.start < cue.end && cue.start < $0.end }) else { return nil }
            return ProposedChange(kind: .insert, cue: cue)
        }
        return ProposedChangeSet(title: "Transcription", changes: changes)
    }

    /// Translated text, with the flag and variants when the line could be translated more than one way.
    public static func translation(_ batch: TranslationBatch, cues: [Cue], title: String = "Translation") -> ProposedChangeSet {
        let byID = Dictionary(cues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let changes: [ProposedChange] = batch.translations.compactMap { translation in
            // Crowd chatter's cue stays empty until the translation is done, then goes.
            guard let cue = byID[translation.cueID], !translation.isWalla else { return nil }
            var after = cue
            after.text = translation.text
            after.flag = translation.flag
            return ProposedChange.update(from: cue, to: after)
        }
        return ProposedChangeSet(title: title, changes: changes, cast: batch.cast)
    }
}
