import EditorCommands
import SpotlineAccessibility
import XCTest

/// The Translate page: Translate with AI stage by stage, and a run with its stops.
final class AIPlanUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheTranslatePageRunsTheStepsAndStopsForTheBriefAndTheLinesToCheck() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestEpisodeBrief"]
        _ = launchApp(prepared: app)
        _ = button(.stepForward, in: app)
        chooseAIMenuItem(.planAIFlow, in: app)

        // The page lists the stages, and the first one's steps are ticked.
        let page = app.descendants(matching: .any)[AccessibilityID.TranslatePage.root]
        XCTAssertTrue(page.waitForExistence(timeout: 10), "Translate with AI… did not show the Translate page")
        for stage in ["source", "brief", "check", "translate", "choices"] {
            XCTAssertTrue(page.descendants(matching: .any)[AccessibilityID.TranslatePage.stage(stage)].exists, "No \(stage) stage")
        }
        XCTAssertEqual(page.checkBoxes[AccessibilityID.AIPlan.tick("listen")].value as? Int, 1)
        page.buttons[AccessibilityID.TranslatePage.startButton].click()

        // It transcribes, builds the brief, and stops for it.
        let brief = app.descendants(matching: .any)[AccessibilityID.Brief.sheet]
        XCTAssertTrue(brief.waitForExistence(timeout: 30), "The run did not stop for the brief")
        brief.buttons[AccessibilityID.Brief.confirmButton].click()

        // The script review flags a line: the page says it waits, and its button goes on.
        let waiting = app.descendants(matching: .any)[AccessibilityID.AIPlan.waiting]
        XCTAssertTrue(waiting.waitForExistence(timeout: 30), "The run did not wait for the line to check")
        XCTAssertEqual(waiting.value as? String, "1 line to check before translating")
        XCTAssertTrue(page.descendants(matching: .any)[AccessibilityID.TranslatePage.waiting].exists, "The stage does not say what it waits for")
        app.buttons.matching(identifier: AccessibilityID.command(EditorCommand.continueAIFlow.id)).firstMatch.click()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: waiting)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 30), .completed, "The run did not end")

        // On the Edit page, the lines are translated.
        app.typeKey("2", modifierFlags: .command)
        let translated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value BEGINSWITH %@", "[ar]"), object: app.cueCells(.text).element(boundBy: 0)
        )
        XCTAssertEqual(XCTWaiter().wait(for: [translated], timeout: 30), .completed, "The lines were not translated")
    }
}
