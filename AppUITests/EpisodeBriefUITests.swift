import EditorCommands
import SpotlineAccessibility
import XCTest

/// The episode brief after transcribing: its dialog, the review waiting for it, then the
/// AI script review's card.
final class EpisodeBriefUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheReviewWaitsForTheBriefThenShowsTheScriptReview() throws {
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
        let plot = sheet.descendants(matching: .any)[AccessibilityID.Brief.plot]
        XCTAssertEqual(plot.value as? String, "Rick wakes Morty to go on an adventure.")
        let scenes = sheet.descendants(matching: .any)[AccessibilityID.Brief.scenes]
        XCTAssertEqual(scenes.value as? String, "0:00 Rick greets Morty, who says he is fine.")

        // Edit, then confirm: the dialog goes and the review shows.
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Rick Sanchez")
        sheet.buttons[AccessibilityID.Brief.confirmButton].click()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sheet)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "Confirm did not close the brief")
        // Then the script review runs, and its card shows with the other checks.
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'review.card.' AND identifier ENDSWITH '.script'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "No AI Review card after the script review")
        XCTAssertFalse(app.descendants(matching: .any)[AccessibilityID.Brief.waiting].exists, "The review still waits")
        let cardID = card.identifier
        let itemID = String(cardID.dropFirst("review.card.".count))
        let fix = app.descendants(matching: .any)[AccessibilityID.Review.fix(itemID, 0)]
        XCTAssertEqual(fix.label, "72% sure")
        fix.click()
        waitForValue(of: app.cueCells(.text).element(boundBy: 0), toEqual: "Hello Rick. How are you?")
        app.descendants(matching: .any)[AccessibilityID.Review.action(itemID, .confirm)].click()
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: card)
        XCTAssertEqual(XCTWaiter().wait(for: [settled], timeout: 10), .completed, "Confirm did not settle the card")

        // AI › Episode Brief… opens it again, as confirmed.
        chooseAIMenuItem(.showEpisodeBrief, in: app)
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Episode Brief… did not open the brief")
        XCTAssertTrue(sheet.textFields.matching(NSPredicate(format: "value == %@", "Rick Sanchez")).firstMatch.exists, "The edit was not kept")
        sheet.buttons[AccessibilityID.Brief.notNowButton].click()
    }

    /// From the brief: the scenes described from a few frames of each, under "In the Video".
    @MainActor
    func testDescribesTheScenesFromTheVideoIntoTheBrief() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestEpisodeBrief"]
        _ = launchApp(prepared: app)
        _ = button(.stepForward, in: app)
        chooseAIMenuItem(.transcribe, in: app)

        let sheet = app.descendants(matching: .any)[AccessibilityID.Brief.sheet]
        XCTAssertTrue(sheet.waitForExistence(timeout: 20), "No brief after transcribing")
        let seen = sheet.descendants(matching: .any)[AccessibilityID.Brief.seen]
        XCTAssertEqual(seen.value as? String, "", "Nothing from the video yet")
        // Sending frames is off: the dialog says so, and its button offers to turn it on.
        let hint = sheet.descendants(matching: .any)[AccessibilityID.Brief.seenHint]
        XCTAssertTrue(hint.label.contains("Send video frames is off"), "The dialog does not say why nothing was described")
        XCTAssertEqual(sheet.buttons[AccessibilityID.command(EditorCommand.describeScenes.id)].label, "Turn On Video Frames and Describe Scenes")
        // From the menu: the dialog's own button is below the fold of its scroll view.
        sheet.buttons[AccessibilityID.Brief.notNowButton].click()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sheet)
        XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: 10), .completed, "Not Now did not close the brief")
        chooseAIMenuItem(.describeScenes, in: app)

        // The frames are picked and described, then the brief opens with what they show.
        let described = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value CONTAINS %@", "In view: Rick"), object: seen)
        XCTAssertEqual(XCTWaiter().wait(for: [described], timeout: 40), .completed, "The scenes were not described")
        sheet.buttons[AccessibilityID.Brief.notNowButton].click()
    }
}
