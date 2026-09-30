import Foundation
import Testing
@testable import SubtitleCore

struct EpisodeBriefTests {
    @Test func mergingTwoVoicesMakesOnePerson() {
        let dunk = EpisodeBrief.Person(voices: ["speaker_0"], name: "Dunk", gender: .male)
        let split = EpisodeBrief.Person(voices: ["speaker_3"], name: "", confidence: 0)
        var brief = EpisodeBrief(people: [dunk, split], targetLanguage: "ar")
        brief.merge(split.id, into: dunk.id)
        #expect(brief.people.map(\.name) == ["Dunk"])
        #expect(brief.people[0].voices == ["speaker_0", "speaker_3"])
        // Merging into itself or someone gone does nothing.
        brief.merge(dunk.id, into: dunk.id)
        brief.merge(UUID(), into: dunk.id)
        #expect(brief.people.count == 1)
    }

    @Test func everyVoiceGetsARow() {
        var brief = EpisodeBrief(people: [EpisodeBrief.Person(voices: ["speaker_0"], name: "Dunk")], targetLanguage: "ar")
        brief.addMissingVoices(["speaker_0", "speaker_1"])
        #expect(brief.people.map(\.voices) == [["speaker_0"], ["speaker_1"]])
        #expect(brief.people[1].name.isEmpty)
    }

    @Test func confirmingPutsThePeopleInTheCastWithTheirGendersSettled() {
        var track = SubtitleTrack(cast: [
            CastMember(name: "Dunk", gender: .female, voices: ["speaker_0", "speaker_5"], translatedName: "دنك"),
            CastMember(name: "Egg", gender: .male, isConfirmed: true),
        ])
        let brief = EpisodeBrief(
            people: [
                EpisodeBrief.Person(voices: ["speaker_0"], name: "Dunk", gender: .male, translatedName: "دانك"),
                EpisodeBrief.Person(voices: ["speaker_5"], name: "Lyonel", gender: .male, translatedName: "ليونيل"),
                EpisodeBrief.Person(voices: ["speaker_1"], name: "Egg", gender: .unknown),
                EpisodeBrief.Person(voices: ["speaker_2"], name: " ", gender: .female),
            ],
            targetLanguage: "ar"
        )
        track.confirm(brief)
        #expect(track.brief?.isConfirmed == true)
        #expect(track.cast.map(\.name) == ["Dunk", "Egg", "Lyonel"])
        let dunk = track.cast[0]
        #expect(dunk.gender == .male && dunk.isConfirmed)
        #expect(dunk.translatedName == "دانك")
        // A voice belongs to one person.
        #expect(dunk.voices == ["speaker_0"])
        #expect(track.cast[2].voices == ["speaker_5"])
        // Left unknown, a gender settled before stays.
        #expect(track.cast[1].gender == .male && track.cast[1].isConfirmed)
        #expect(track.cast[1].voices == ["speaker_1"])
    }

    @Test func projectsSavedBeforeBriefsHaveNone() throws {
        let data = Data(#"{"id": "00000000-0000-0000-0000-000000000001", "languageCode": "en", "cues": []}"#.utf8)
        let track = try JSONDecoder().decode(SubtitleTrack.self, from: data)
        #expect(track.brief == nil)
        var withBrief = track
        withBrief.brief = EpisodeBrief(people: [EpisodeBrief.Person(voices: ["speaker_0"], name: "Dunk")], targetLanguage: "ar", work: "Pilot")
        let decoded = try JSONDecoder().decode(SubtitleTrack.self, from: JSONEncoder().encode(withBrief))
        #expect(decoded.brief == withBrief.brief)
        // Briefs saved before the plot and scenes have none.
        let early = Data(#"{"people": [], "terms": [], "targetLanguage": "ar", "isConfirmed": true}"#.utf8)
        let brief = try JSONDecoder().decode(EpisodeBrief.self, from: early)
        #expect(brief.plot.isEmpty && brief.scenes.isEmpty && brief.storyNotes == nil)
    }

    @Test func thePlotAndScenesBecomeNotes() {
        let brief = EpisodeBrief(plot: "Dunk rides to Ashford.", scenes: "0:00 Dunk talks to Egg.", targetLanguage: "ar")
        #expect(brief.storyNotes == "Plot: Dunk rides to Ashford.\n\nScenes (time, who talks to whom):\n0:00 Dunk talks to Egg.")
        #expect(EpisodeBrief(plot: " ", targetLanguage: "ar").storyNotes == nil)
    }
}
