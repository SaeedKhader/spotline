import EditorCommands
import SpotlineAccessibility
import XCTest

final class MainWindowUITests: XCTestCase {
    @MainActor
    func testMainWindowShowsEditorRegions() throws {
        let app = launchApp()
        for id in [
            AccessibilityID.Video.surface,
            AccessibilityID.Inspector.root,
            AccessibilityID.Transport.root,
            AccessibilityID.Timeline.root,
            AccessibilityID.CueList.root,
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

    // MARK: - Helpers

    @MainActor
    private func launchApp(openFixture: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMode", "-ApplePersistenceIgnoreState", "YES"]
        if openFixture {
            let fixture = Bundle(for: Self.self).url(forResource: "testsrc-23.976", withExtension: "mp4")
            app.launchArguments += ["-OpenMedia", fixture!.path]
        }
        app.launch()
        app.activate()
        // The editor window must appear at launch without being asked for.
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 10),
            "No editor window at launch. Accessibility hierarchy:\n\(app.debugDescription)"
        )
        return app
    }

    /// The button for `command`, once it exists and is enabled (media has loaded).
    @MainActor
    private func button(_ command: EditorCommand, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[AccessibilityID.command(command.id)]
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"), object: button
        )
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 10), .completed, "\(command.id) never became enabled")
        return button
    }

    /// Waits for an element's accessibility value to become `expected`.
    @MainActor
    private func waitForValue(
        of element: XCUIElement,
        toEqual expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: element)
        let result = XCTWaiter().wait(for: [match], timeout: 10)
        let actual = element.value as? String ?? "nil"
        XCTAssertEqual(result, .completed, "Expected \(expected), got \(actual)", file: file, line: line)
    }
}
