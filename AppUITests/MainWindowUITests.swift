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
    func testSteppingForwardAdvancesTimecode() throws {
        let app = launchApp()
        let stepForward = app.buttons[AccessibilityID.command(EditorCommand.stepForward.id)]
        XCTAssertTrue(stepForward.waitForExistence(timeout: 10))

        for _ in 0..<10 { stepForward.click() }

        let timecode = app.staticTexts[AccessibilityID.Transport.timecode]
        XCTAssertEqual(timecode.value as? String, "00:00:00:10")
    }

    @MainActor
    func testStepBackwardIsDisabledAtStart() throws {
        let app = launchApp()
        let stepBackward = app.buttons[AccessibilityID.command(EditorCommand.stepBackward.id)]
        XCTAssertTrue(stepBackward.waitForExistence(timeout: 10))
        XCTAssertFalse(stepBackward.isEnabled)
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMode", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.activate()
        let window = app.windows.firstMatch
        XCTAssertTrue(
            window.waitForExistence(timeout: 15),
            "Main window did not appear. Accessibility hierarchy:\n\(app.debugDescription)"
        )
        return app
    }
}
