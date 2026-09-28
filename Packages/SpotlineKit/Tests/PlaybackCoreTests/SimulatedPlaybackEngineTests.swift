import Foundation
import Testing
import SubtitleCore
@testable import PlaybackCore

@MainActor
struct SimulatedPlaybackEngineTests {
    let media = URL(fileURLWithPath: "/tmp/clip.mov")

    @Test func requestsWithoutMediaAreIgnored() {
        let engine = SimulatedPlaybackEngine()
        engine.step(by: 1)
        engine.setPaused(false)
        #expect(engine.status == PlaybackStatus())
    }

    @Test func steppingIsClampedToTheMedia() {
        let engine = SimulatedPlaybackEngine(frameRate: .fps25, frameCount: 3)
        engine.load(media)
        engine.step(by: -1)
        #expect(engine.status.position == .zero)
        engine.step(by: 5)
        #expect(engine.status.position.nearestFrame(at: .fps25) == 2)
        #expect(engine.status.isAtEnd)
    }

    @Test func seekingConvertsBetweenRates() {
        let engine = SimulatedPlaybackEngine(frameRate: .fps25, frameCount: 1_000)
        engine.load(media)
        engine.seek(toFrame: 50, rate: .fps50)
        #expect(engine.status.position == MediaTime(seconds: 1))
    }
}
