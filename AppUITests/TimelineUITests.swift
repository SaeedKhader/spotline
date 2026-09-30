import EditorCommands
import SpotlineAccessibility
import XCTest

/// M3: waveform and shot-change analysis, cue blocks on the timeline, snapping.
/// cuts-25.mp4 is 4 s at 25 fps with cuts at frames 40 (00:00:01:15) and 75 (00:00:03:00).
final class TimelineUITests: XCTestCase {
    @MainActor
    private func launchCuts() -> XCUIApplication {
        let app = launchApp(openSubtitles: true, media: "cuts-25.mp4", subtitles: "cuts-25.srt")
        waitForValue(of: app.staticTexts[AccessibilityID.Transport.analysis], toEqual: "2 shot changes")
        return app
    }

    @MainActor
    func testAnalysisFindsTheShotChanges() throws {
        let app = launchCuts()
        let first = app.descendants(matching: .any)[AccessibilityID.Timeline.shotChange(0)]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertEqual(first.value as? String, "00:00:01:15")
        XCTAssertEqual(app.descendants(matching: .any)[AccessibilityID.Timeline.shotChange(1)].value as? String, "00:00:03:00")
        XCTAssertEqual(app.timelineHandles(".outHandle").count, 3)
    }

    @MainActor
    func testNextShotChangeMovesThePlayhead() throws {
        let app = launchCuts()
        app.typeKey(.rightArrow, modifierFlags: .option)
        waitForValue(of: app.timecode, toEqual: "00:00:01:15")
        app.typeKey(.rightArrow, modifierFlags: .option)
        waitForValue(of: app.timecode, toEqual: "00:00:03:00")
        app.typeKey(.leftArrow, modifierFlags: .option)
        waitForValue(of: app.timecode, toEqual: "00:00:01:15")
    }

    @MainActor
    func testDraggingAnOutPointSnapsToTheShotChange() throws {
        let app = launchCuts()
        let outHandle = app.timelineHandles(".outHandle").element(boundBy: 0)
        XCTAssertTrue(outHandle.waitForExistence(timeout: 10))
        let shotChange = app.descendants(matching: .any)[AccessibilityID.Timeline.shotChange(0)]
        XCTAssertTrue(shotChange.exists)
        // Aim a little short of the cut; snapping pulls the edge onto it.
        let start = outHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let distance = shotChange.frame.midX - outHandle.frame.midX - 4
        start.click(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: distance, dy: 0)))

        waitForValue(of: app.cueCells(.outPoint).element(boundBy: 0), toEqual: "00:00:01:15")
        app.typeKey("z", modifierFlags: .command)
        waitForValue(of: app.cueCells(.outPoint).element(boundBy: 0), toEqual: "00:00:01:00")
    }

    @MainActor
    func testDraggingACueMovesIt() throws {
        let app = launchCuts()
        app.menuBars.menuItems[EditorCommand.toggleSnapping.title].click()
        let cue = app.timelineCueBlocks.element(boundBy: 1)
        XCTAssertTrue(cue.waitForExistence(timeout: 10))
        // 100 points per second: 25 points is a quarter second, about 6 frames at 25 fps.
        // (A bigger move would run into "Blue" at 3.2 s, which cues may not overlap.)
        let start = cue.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.click(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 25, dy: 0)))

        // "After the cut" started at frame 50 and keeps its 20-frame duration.
        let inPoint = app.cueCells(.inPoint).element(boundBy: 1)
        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value IN %@", ["00:00:02:05", "00:00:02:06", "00:00:02:07"]), object: inPoint
        )
        XCTAssertEqual(XCTWaiter().wait(for: [moved], timeout: 10), .completed, "In is \(inPoint.value ?? "nil")")
        let outPoint = app.cueCells(.outPoint).element(boundBy: 1).value as? String
        XCTAssertTrue(["00:00:03:00", "00:00:03:01", "00:00:03:02"].contains(outPoint ?? ""), "Out is \(outPoint ?? "nil")")
    }

    @MainActor
    func testDraggingEmptyTimelineScrubsUnderTheCenteredPlayhead() throws {
        let app = launchCuts()
        let timeline = app.descendants(matching: .any)[AccessibilityID.Timeline.root]
        let playhead = app.descendants(matching: .any)[AccessibilityID.Timeline.playhead]
        XCTAssertTrue(playhead.waitForExistence(timeout: 10))
        XCTAssertEqual(playhead.frame.midX, timeline.frame.midX, accuracy: 3, "The playhead is not centered")

        // Just under the ruler, above the cue blocks: empty space. 100 points is one second.
        let start = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0)).withOffset(CGVector(dx: 0, dy: 26))
        start.click(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: -100, dy: 0)))
        let scrubbed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value IN %@", ["00:00:00:24", "00:00:01:00", "00:00:01:01"]), object: app.timecode
        )
        XCTAssertEqual(XCTWaiter().wait(for: [scrubbed], timeout: 10), .completed, "Timecode is \(app.timecode.value ?? "nil")")
        XCTAssertEqual(playhead.frame.midX, timeline.frame.midX, accuracy: 3, "The playhead moved off center")
    }

    @MainActor
    func testClickingACueGoesToItAndEmptySpaceDeselects() throws {
        let app = launchCuts()
        let cue = app.timelineCueBlocks.element(boundBy: 1)
        XCTAssertTrue(cue.waitForExistence(timeout: 10))
        cue.click()
        // "After the cut" starts at 2 s.
        waitForValue(of: app.timecode, toEqual: "00:00:02:00")
        let delete = app.buttons[AccessibilityID.command(EditorCommand.deleteCue.id)]
        XCTAssertTrue(delete.isEnabled)

        let timeline = app.descendants(matching: .any)[AccessibilityID.Timeline.root]
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0)).withOffset(CGVector(dx: 0, dy: 26)).click()
        let deselected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: delete)
        XCTAssertEqual(XCTWaiter().wait(for: [deselected], timeout: 10), .completed, "The cue is still selected")
        waitForValue(of: app.timecode, toEqual: "00:00:02:00")
    }

    /// two-tracks.mkv: an English stereo track (default) and an Arabic 5.1 track.
    @MainActor
    func testSwitchingAudioTracksRedrawsTheWaveform() throws {
        let app = launchApp(media: "two-tracks.mkv")
        let timeline = app.descendants(matching: .any)[AccessibilityID.Timeline.root]
        waitForValue(of: timeline, toEqual: "Waveform: all channels mixed, speech highlighted")

        // Pick the second track from Playback › Audio Track while the video
        // plays: the playhead must not redraw (and break) the open menu.
        button(EditorCommand.togglePlay, in: app).click()
        let dialogue = "Waveform: center channel (dialogue), speech highlighted"
        // Nested menus are sometimes dismissed by synthesized mouse moves, so
        // the menu path gets a second try before the test fails.
        for attempt in 1...2 where (timeline.value as? String) != dialogue {
            pickAudioTrack(containing: "Arabic dub", in: app)
            let switched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", dialogue), object: timeline)
            if XCTWaiter().wait(for: [switched], timeout: 10) != .completed, attempt == 2 {
                XCTFail("Choosing a track from the menu did not switch it (\(timeline.value ?? "nil"))")
            }
        }

        app.typeKey("a", modifierFlags: [.command, .option])
        waitForValue(of: timeline, toEqual: "Waveform: all channels mixed, speech highlighted")
    }

    @MainActor
    private func pickAudioTrack(containing title: String, in app: XCUIApplication) {
        let playback = app.menuBars.menuBarItems["Playback"]
        playback.click()
        let audioTrack = playback.menus.menuItems["Audio Track"]
        XCTAssertTrue(audioTrack.waitForExistence(timeout: 5))
        audioTrack.click()
        let item = audioTrack.menus.menuItems.matching(NSPredicate(format: "title CONTAINS %@", title)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Audio Track submenu did not open")
        item.click()
    }
}
