import EditorCommands
import SpotlineAccessibility
import XCTest

/// AI › Translate with AI…: the plan of every step, and a run of it with its stops.
final class AIPlanUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testThePlanRunsTheStepsAndStopsForTheBriefAndTheLinesToCheck() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestEpisodeBrief"]
        _ = launchApp(prepared: app)
        _ = button(.stepForward, in: app)
        chooseAIMenuItem(.planAIFlow, in: app)

        // The plan lists every step; a new video gets them all but the scenes.
        let plan = app.descendants(matching: .any)[AccessibilityID.AIPlan.sheet]
        XCTAssertTrue(plan.waitForExistence(timeout: 10), "Translate with AI… did not open the plan")
        for step in ["listen", "brief", "scenes", "scriptReview", "translate", "join"] {
            XCTAssertTrue(plan.descendants(matching: .any)[AccessibilityID.AIPlan.row(step)].exists, "No row for \(step)")
        }
        XCTAssertEqual(plan.checkBoxes[AccessibilityID.AIPlan.tick("listen")].value as? Int, 1)
        XCTAssertEqual(plan.checkBoxes[AccessibilityID.AIPlan.tick("scenes")].value as? Int, 0, "Frames are not sent unless ticked")
        plan.buttons[AccessibilityID.AIPlan.startButton].click()

        // It transcribes, builds the brief, and stops for it.
        let brief = app.descendants(matching: .any)[AccessibilityID.Brief.sheet]
        XCTAssertTrue(brief.waitForExistence(timeout: 30), "The run did not stop for the brief")
        waitForValue(of: app.cueCells(.text).element(boundBy: 0), toEqual: "Hello there. How are you?")
        brief.buttons[AccessibilityID.Brief.confirmButton].click()

        // The script review flags a line: the AI bar says it waits, and its button goes on.
        let waiting = app.descendants(matching: .any)[AccessibilityID.AIPlan.waiting]
        XCTAssertTrue(waiting.waitForExistence(timeout: 30), "The run did not wait for the line to check")
        XCTAssertEqual(waiting.value as? String, "1 line to check before translating")
        app.buttons[AccessibilityID.command(EditorCommand.continueAIFlow.id)].click()

        // Then it translates.
        let translated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value BEGINSWITH %@", "[ar]"), object: app.cueCells(.text).element(boundBy: 0)
        )
        XCTAssertEqual(XCTWaiter().wait(for: [translated], timeout: 30), .completed, "The lines were not translated")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: waiting)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "The run did not end")
    }
}
