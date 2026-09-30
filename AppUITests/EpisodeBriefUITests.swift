import EditorCommands
import SpotlineAccessibility
import XCTest

/// The episode brief after transcribing: its dialog, and the review waiting for it.
final class EpisodeBriefUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheReviewWaitsUntilTheBriefIsConfirmed() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestEpisodeBrief"]
        _ = launchApp(prepared: app)
        _ = button(.stepForward, in: app)
        chooseAIMenuItem(.transcribe, in: app)

        // The brief opens by itself once it is built, and the review waits for it.
        let sheet = app.descendants(matching: .any)[AccessibilityID.Brief.sheet]
        XCTAssertTrue(sheet.waitForExistence(timeout: 20), "No brief after transcribing")
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.Brief.waiting].exists, "The review did not wait for the brief")
        let name = sheet.textFields.matching(NSPredicate(format: "value == %@", "Rick")).firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5), "The brief's person is missing")
        XCTAssertTrue(sheet.textFields.matching(NSPredicate(format: "value == %@", "ريك")).firstMatch.exists, "The Arabic spelling is missing")
        XCTAssertTrue(sheet.textFields.matching(NSPredicate(format: "value == %@", "Citadel")).firstMatch.exists, "The term is missing")

        // Edit, then confirm: the dialog goes and the review shows.
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Rick Sanchez")
        sheet.buttons[AccessibilityID.Brief.confirmButton].click()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sheet)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "Confirm did not close the brief")
        XCTAssertFalse(app.descendants(matching: .any)[AccessibilityID.Brief.waiting].exists, "The review still waits")

        // AI › Episode Brief… opens it again, as confirmed.
        chooseAIMenuItem(.showEpisodeBrief, in: app)
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Episode Brief… did not open the brief")
        XCTAssertTrue(sheet.textFields.matching(NSPredicate(format: "value == %@", "Rick Sanchez")).firstMatch.exists, "The edit was not kept")
        sheet.buttons[AccessibilityID.Brief.notNowButton].click()
    }
}
