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
        // 100 points per second: 20 points is half a second, 12 or 13 frames at 25 fps.
        let start = cue.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.click(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 50, dy: 0)))

        // "After the cut" started at frame 50; half a second later is frame 62 or 63.
        let inPoint = app.cueCells(.inPoint).element(boundBy: 1)
        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value IN %@", ["00:00:02:12", "00:00:02:13"]), object: inPoint
        )
        XCTAssertEqual(XCTWaiter().wait(for: [moved], timeout: 10), .completed, "In is \(inPoint.value ?? "nil")")
        XCTAssertEqual(app.cueCells(.duration).element(boundBy: 1).value as? String, "0.800")
    }

    /// two-tracks.mkv: an English stereo track (default) and an Arabic 5.1 track.
    @MainActor
    func testSwitchingAudioTracksRedrawsTheWaveform() throws {
        let app = launchApp(media: "two-tracks.mkv")
        let timeline = app.descendants(matching: .any)[AccessibilityID.Timeline.root]
        let picker = app.popUpButtons[AccessibilityID.Transport.audioTrack]
        waitForValue(of: timeline, toEqual: "Waveform: all channels mixed")
        XCTAssertTrue((picker.value as? String)?.contains("Original") == true, "\(picker.value ?? "nil")")

        app.typeKey("a", modifierFlags: [.command, .option])
        waitForValue(of: timeline, toEqual: "Waveform: center channel (dialogue)")
        XCTAssertTrue((picker.value as? String)?.contains("Arabic dub") == true, "\(picker.value ?? "nil")")

        picker.click()
        app.menuItems.matching(NSPredicate(format: "title CONTAINS 'Original'")).firstMatch.click()
        waitForValue(of: timeline, toEqual: "Waveform: all channels mixed")
    }
}
