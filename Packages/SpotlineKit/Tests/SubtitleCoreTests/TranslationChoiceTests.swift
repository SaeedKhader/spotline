import Foundation
import Testing
@testable import SubtitleCore

struct TranslationChoiceTests {
    let toBeth = TranslationVariant(text: "انتِ", listeners: ["Beth"], listenerGender: .female, listenerCount: .one)
    let toBethAsMan = TranslationVariant(text: "انت", listeners: ["Beth"], listenerGender: .male, listenerCount: .one)
    let bethSpeaking = TranslationVariant(text: "أنا متعبة", speaker: "Beth", speakerGender: .female)
    let bethSpeakingAsMan = TranslationVariant(text: "أنا متعب", speaker: "Beth", speakerGender: .male)

    @Test func variantsFitOnlyWhatIsConfirmed() {
        let guessed = [CastMember(name: "Beth", gender: .male)]
        #expect(toBeth.fits(guessed), "A guess is no fact")
        let confirmed = [CastMember(name: "beth ", gender: .female, isConfirmed: true)]
        #expect(toBeth.fits(confirmed))
        #expect(!toBethAsMan.fits(confirmed))
        #expect(bethSpeaking.fits(confirmed) && !bethSpeakingAsMan.fits(confirmed))
        #expect(TranslationVariant(text: "?", listeners: ["Morty"], listenerGender: .female).fits(confirmed), "Nothing known about Morty")
    }

    @Test func aChoiceTheTranslatorWasSureOfIsNotPutUpForReview() {
        let sure = TranslationFlag(reasons: [.listener], variants: [toBeth, toBethAsMan], confidence: 1, note: "Jerry is talking to Beth")
        #expect(sure.settledWhenSure.isResolved)
        #expect(sure.settledWhenSure.variants == sure.variants, "The other reading stays, to swap in")
        // 99% still reads as a doubt.
        let nearly = TranslationFlag(reasons: [.listener], variants: [toBeth, toBethAsMan], confidence: 0.99, note: "")
        #expect(!nearly.settledWhenSure.isResolved)
        var track = SubtitleTrack(cues: [
            Cue(start: .zero, end: MediaTime(value: 1, timescale: 1), text: "انتِ", flag: sure),
            Cue(start: MediaTime(value: 2, timescale: 1), end: MediaTime(value: 3, timescale: 1), text: "انتِ", flag: nearly),
        ])
        track.settleSureFlags()
        #expect(track.cues.map { $0.flag?.isResolved } == [true, false])
    }

    @Test func groupsFitTheirMembers() {
        let cast = [CastMember(name: "Beth", gender: .female, isConfirmed: true), CastMember(name: "Summer", gender: .female, isConfirmed: true),
                    CastMember(name: "Jerry", gender: .male, isConfirmed: true)]
        let women = TranslationVariant(text: "انتما", listeners: ["Beth", "Summer"], listenerGender: .female, listenerCount: .two)
        let mixedAsWomen = TranslationVariant(text: "انتن", listeners: ["Beth", "Jerry"], listenerGender: .female, listenerCount: .two)
        let mixed = TranslationVariant(text: "انتم", listeners: ["Beth", "Jerry"], listenerGender: .mixed, listenerCount: .two)
        #expect(women.fits(cast))
        #expect(!mixedAsWomen.fits(cast))
        #expect(mixed.fits(cast))
    }

    @Test func rerankingSwitchesAndSettles() {
        let cast = [CastMember(name: "Beth", gender: .female, isConfirmed: true)]
        var flag = TranslationFlag(reasons: [.listener], variants: [toBethAsMan, toBeth], confidence: 0.6, note: "")
        let switched = flag.rerank(with: cast)
        #expect(switched)
        #expect(flag.variants == [toBeth, toBethAsMan])
        #expect(flag.chosen == 0 && flag.isResolved && flag.confidence == 1)

        // Two variants still fit: reordered, the choice stays open, the current one kept.
        let group = TranslationVariant(text: "انتم", listenerGender: .mixed, listenerCount: .many)
        var open = TranslationFlag(reasons: [.listener], variants: [group, toBethAsMan, toBeth], confidence: 0.5, note: "")
        let openSwitched = open.rerank(with: cast)
        #expect(!openSwitched)
        #expect(open.variants == [group, toBeth, toBethAsMan])
        #expect(open.chosen == 0 && !open.isResolved)

        // Resolved flags and unconfirmed casts are left alone.
        var decided = TranslationFlag(reasons: [.listener], variants: [toBethAsMan, toBeth], confidence: 0.6, note: "", isResolved: true)
        let decidedSwitched = decided.rerank(with: cast)
        #expect(!decidedSwitched)
        var unknown = TranslationFlag(reasons: [.listener], variants: [toBethAsMan, toBeth], confidence: 0.6, note: "")
        let unknownSwitched = unknown.rerank(with: [CastMember(name: "Beth", gender: .female)])
        #expect(!unknownSwitched)
    }

    @Test func choosingConfirmsAndCarriesForward() {
        var first = Cue(start: .zero, end: MediaTime(value: 1, timescale: 1), text: toBethAsMan.text)
        first.flag = TranslationFlag(reasons: [.listener], variants: [toBethAsMan, toBeth], confidence: 0.5, note: "")
        var second = Cue(start: MediaTime(value: 2, timescale: 1), end: MediaTime(value: 3, timescale: 1), text: bethSpeakingAsMan.text)
        second.flag = TranslationFlag(reasons: [.speaker], variants: [bethSpeakingAsMan, bethSpeaking], confidence: 0.7, note: "")
        var track = SubtitleTrack(cues: [first, second])
        let changed = track.choose(variant: 1, forCue: first.id)
        #expect(track.cues[0].text == "انتِ" && track.cues[0].flag?.chosen == 1 && track.cues[0].flag?.isResolved == true)
        #expect(track.cast == [CastMember(id: track.cast[0].id, name: "Beth", gender: .female, isConfirmed: true)])
        #expect(changed == [second.id])
        #expect(track.cues[1].text == "أنا متعبة")

        let none = track.choose(variant: 5, forCue: first.id)
        #expect(none.isEmpty, "No such variant")
    }

    @Test func mergingKeepsWhatWasConfirmed() {
        var cast = [CastMember(name: "Beth", gender: .female, isConfirmed: true, voices: ["speaker_0"])]
        cast.merge([
            CastMember(name: "BETH", gender: .male, voices: ["speaker_0", "speaker_3"]),
            CastMember(name: "Morty", gender: .unknown), CastMember(name: " "),
        ])
        #expect(cast.map(\.name) == ["Beth", "Morty"])
        #expect(cast[0].gender == .female && cast[0].voices == ["speaker_0", "speaker_3"])
        cast.merge([CastMember(name: "Morty", gender: .male)])
        #expect(cast[1].gender == .male && !cast[1].isConfirmed)
        cast.confirm("Morty", as: .unknown)
        #expect(!cast[1].isConfirmed, "Only a gender can be confirmed")
    }

    @Test func resolvingKeepsTheText() {
        var cue = Cue(start: .zero, end: MediaTime(value: 1, timescale: 1), text: toBeth.text)
        cue.flag = TranslationFlag(reasons: [.listener], variants: [toBeth, toBethAsMan], confidence: 0.5, note: "")
        var track = SubtitleTrack(cues: [cue])
        track.resolveFlags()
        #expect(track.cues[0].text == toBeth.text && track.cues[0].flag?.isResolved == true)
    }
}
