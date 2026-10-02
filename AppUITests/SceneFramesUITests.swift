import EditorCommands
import SpotlineAccessibility
import XCTest

/// AI › Scene Frames…: the frames picked for each scene, read from the video itself.
final class SceneFramesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testPicksAndShowsTheFramesOfTheScenes() throws {
        let app = launchApp(openSubtitles: true, media: "cuts-25.mp4", subtitles: "cuts-25.srt")
        _ = button(.stepForward, in: app)
        chooseAIMenuItem(.showSceneFrames, in: app)

        let sheet = app.descendants(matching: .any)[AccessibilityID.SceneFrames.sheet]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Scene Frames… did not open the dialog")
        let summary = sheet.descendants(matching: .any)[AccessibilityID.SceneFrames.summary]
        XCTAssertTrue(summary.waitForExistence(timeout: 30), "The frames were never picked")
        XCTAssertTrue(sheet.descendants(matching: .any)[AccessibilityID.SceneFrames.scene(1)].exists, "No scene")
        let frame = sheet.descendants(matching: .any)[AccessibilityID.SceneFrames.frame(1, 1)]
        XCTAssertTrue(frame.exists, "No frame was kept for the scene")
        XCTAssertTrue(sheet.buttons[AccessibilityID.command(EditorCommand.exportSceneFrames.id)].isEnabled)

        // The scene opens to show its lines.
        sheet.descendants(matching: .any)[AccessibilityID.SceneFrames.details(1)].click()
        XCTAssertTrue(sheet.staticTexts["Before the cut"].waitForExistence(timeout: 5), "The scene did not open to its lines")

        sheet.buttons[AccessibilityID.SceneFrames.doneButton].click()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sheet)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "Done did not close the dialog")
    }
}
