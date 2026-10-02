import AppKit
import PlaybackCore
import SubtitleCore
import Testing
@testable import EditorUI

/// The timeline's picture is drawn in tiles that slide as the media plays: a frame of video
/// moves them and draws nothing, a change to what they show draws them again.
@MainActor
struct TimelineTileTests {
    let rate = FrameRate.fps25

    func makeView() -> TimelineView {
        let editor = EditorState(launchOptions: LaunchOptions(isUITestMode: true), playback: SimulatedPlaybackEngine(frameRate: rate), frameRate: rate)
        let view = TimelineView(editor: editor)
        view.setFrameSize(NSSize(width: 1000, height: 110))
        var content = TimelineContent()
        content.hasMedia = true
        content.duration = MediaTime(seconds: 600)
        content.frameRate = rate
        content.playhead = MediaTime(seconds: 300)
        content.cues = [Cue(start: MediaTime(seconds: 299), end: MediaTime(seconds: 301), text: "Hello")]
        view.content = content
        return view
    }

    @Test func tilesCoverTheViewEdgeToEdge() {
        let view = makeView()
        let frames = view.tileFrames
        #expect(frames.first.map { $0.minX <= 0 } == true)
        #expect(frames.last.map { $0.maxX >= 1000 } == true)
        for (left, right) in zip(frames, frames.dropFirst()) { #expect(left.maxX == right.minX) }
        #expect(frames.allSatisfy { $0.height == 110 })
    }

    @Test func aFrameOfPlaybackSlidesTheTilesAndDrawsNone() {
        let view = makeView()
        view.drawNow()
        #expect(view.tilesToDraw == 0)
        let before = view.tileFrames
        var content = view.content
        content.playhead = content.playhead + MediaTime(frame: 1, rate: rate)
        view.content = content
        #expect(view.tilesToDraw == 0)
        // One frame at 25 fps and 100 points a second: four points to the left.
        #expect(view.tileFrames.first.map { $0.minX } == before.first.map { $0.minX - 4 })
    }

    @Test func playingOnBringsNewTilesInAndDropsOldOnes() {
        let view = makeView()
        view.drawNow()
        var content = view.content
        content.playhead = content.playhead + MediaTime(seconds: 60)
        view.content = content
        let frames = view.tileFrames
        #expect(frames.first.map { $0.minX <= 0 } == true)
        #expect(frames.last.map { $0.maxX >= 1000 } == true)
        #expect(frames.count <= 5)
        #expect(view.tilesToDraw == frames.count)
    }

    @Test func aChangeToTheCuesDrawsTheTilesAgain() {
        let view = makeView()
        view.drawNow()
        var content = view.content
        content.cues[0].text = "Hello there"
        view.content = content
        #expect(view.tilesToDraw == view.tileFrames.count)
        view.drawNow()
        // Zooming makes each tile another stretch of the media: all are new.
        content.scale = 50
        view.content = content
        #expect(view.tilesToDraw == view.tileFrames.count)
        #expect(view.tileFrames.first.map { $0.minX <= 0 } == true)
        #expect(view.tileFrames.last.map { $0.maxX >= 1000 } == true)
    }
}
