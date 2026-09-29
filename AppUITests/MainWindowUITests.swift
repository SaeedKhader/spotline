import EditorCommands
import SpotlineAccessibility
import XCTest

final class MainWindowUITests: XCTestCase {
    @MainActor
    func testMainWindowShowsEditorRegions() throws {
        let app = launchApp()
        for id in [
            AccessibilityID.Video.surface,
            AccessibilityID.CueList.root,
            AccessibilityID.Transport.root,
            AccessibilityID.MiniMap.root,
            AccessibilityID.Timeline.root,
        ] {
            let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 10), "Missing \(id)")
        }
    }

    @MainActor
    func testFixtureOpensAtItsFrameRate() throws {
        let app = launchApp()
        waitForValue(of: app.staticTexts[AccessibilityID.Transport.frameRate], toEqual: "23.976 fps")
        XCTAssertFalse(app.buttons[AccessibilityID.command(EditorCommand.openMedia.id)].exists)
    }

    @MainActor
    func testSteppingForwardAdvancesTimecode() throws {
        let app = launchApp()
        let stepForward = button(EditorCommand.stepForward, in: app)

        for _ in 0..<10 { stepForward.click() }

        waitForValue(of: app.staticTexts[AccessibilityID.Transport.timecode], toEqual: "00:00:00:10")
    }

    @MainActor
    func testSteppingBackwardAndGoToStart() throws {
        let app = launchApp()
        let stepForward = button(EditorCommand.stepForward, in: app)
        let stepBackward = app.buttons[AccessibilityID.command(EditorCommand.stepBackward.id)]
        let timecode = app.staticTexts[AccessibilityID.Transport.timecode]

        for _ in 0..<5 { stepForward.click() }
        waitForValue(of: timecode, toEqual: "00:00:00:05")
        stepBackward.click()
        stepBackward.click()
        waitForValue(of: timecode, toEqual: "00:00:00:03")

        // Go to Start through its menu shortcut, Command-Left Arrow.
        app.typeKey(.leftArrow, modifierFlags: .command)
        waitForValue(of: timecode, toEqual: "00:00:00:00")
    }

    @MainActor
    func testStepBackwardIsDisabledAtStart() throws {
        let app = launchApp()
        _ = button(EditorCommand.stepForward, in: app)
        XCTAssertFalse(app.buttons[AccessibilityID.command(EditorCommand.stepBackward.id)].isEnabled)
    }

    @MainActor
    func testPlayAndPause() throws {
        let app = launchApp()
        let togglePlay = button(EditorCommand.togglePlay, in: app)
        let timecode = app.staticTexts[AccessibilityID.Transport.timecode]

        togglePlay.click()
        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", "00:00:00:00"), object: timecode
        )
        XCTAssertEqual(XCTWaiter().wait(for: [moved], timeout: 10), .completed, "Playback did not advance")
        togglePlay.click()

        // Once paused, the timecode holds still.
        let pausedAt = timecode.value as? String
        Thread.sleep(forTimeInterval: 0.5)
        let settled = timecode.value as? String
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(timecode.value as? String, settled, "Still playing after pause (paused at \(pausedAt ?? "?"))")
    }

    @MainActor
    func testWithoutMediaOffersOpenAndDisablesPlayback() throws {
        let app = launchApp(openFixture: false)
        XCTAssertTrue(button(EditorCommand.openMedia, in: app).isEnabled)
        XCTAssertFalse(app.buttons[AccessibilityID.command(EditorCommand.togglePlay.id)].isEnabled)
        XCTAssertFalse(app.buttons[AccessibilityID.command(EditorCommand.stepForward.id)].isEnabled)
    }
}
