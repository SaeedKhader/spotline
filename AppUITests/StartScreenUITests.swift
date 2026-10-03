import EditorCommands
import SpotlineAccessibility
import XCTest

/// A new window's start screen, after a video: which subtitle to work from, then Just Edit or Translate.
final class StartScreenUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The test clip has its subtitle file beside it, which the question recommends.
    @MainActor
    private func launchOnTheQuestion(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestStartScreen"] + extra
        _ = launchApp(prepared: app)
        let start = app.descendants(matching: .any)[AccessibilityID.Start.root]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "No start screen")
        let translate = app.buttons[AccessibilityID.Start.translateButton]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: translate)
        XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 10), .completed, "The subtitle beside the video was not offered")
        return app
    }

    @MainActor
    func testJustEditOpensTheEditorWithTheSubtitleFound() throws {
        let app = launchOnTheQuestion()
        app.buttons[AccessibilityID.Start.justEditButton].click()
        let start = app.descendants(matching: .any)[AccessibilityID.Start.root]
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: start)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "Just Edit did not leave the start screen")
        XCTAssertTrue(app.cueCells(.text).element(boundBy: 0).waitForExistence(timeout: 10), "The subtitle's cues are not in the editor")
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.TranslatePage.switcher].exists, "No page switch")
    }

    @MainActor
    func testTranslateShowsTheTranslatePageAndStarts() throws {
        let app = launchOnTheQuestion(["-UITestEpisodeBrief"])
        app.buttons[AccessibilityID.Start.translateButton].click()
        let page = app.descendants(matching: .any)[AccessibilityID.TranslatePage.root]
        XCTAssertTrue(page.waitForExistence(timeout: 10), "Translate did not show the Translate page")
        // It runs by itself up to the brief.
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.Brief.sheet].waitForExistence(timeout: 30), "The run did not reach the brief")
    }
}
