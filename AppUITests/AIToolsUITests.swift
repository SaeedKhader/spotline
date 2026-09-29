import EditorCommands
import SpotlineAccessibility
import XCTest

/// AI tools with scripted providers (UI test mode): results show as a diff and
/// change nothing until accepted.
final class AIToolsUITests: XCTestCase {
    @MainActor
    func chooseAIMenuItem(_ command: EditorCommand, in app: XCUIApplication) {
        app.menuBars.menuBarItems["AI"].click()
        let item = app.menuBars.menuItems[command.title]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "No \(command.title) menu item")
        item.click()
    }

    @MainActor
    func testTranscriptionIsReviewedBeforeItApplies() throws {
        let app = launchApp()
        _ = button(.stepForward, in: app)
        chooseAIMenuItem(.transcribe, in: app)

        let review = app.descendants(matching: .any)[AccessibilityID.CueList.aiReview]
        XCTAssertTrue(review.waitForExistence(timeout: 20), "No review after transcribing")
        waitForValue(of: review, toEqual: "Transcription: 2 changes to review")
        let proposed = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'cueList.proposed.' AND identifier ENDSWITH '.text'")
        )
        XCTAssertEqual(proposed.count, 2)
        XCTAssertEqual(proposed.element(boundBy: 0).value as? String, "Hello there. How are you?")
        XCTAssertEqual(app.cueCells(.text).count, 0, "Nothing is applied before review")

        // Accept the first cue on its own, then the rest at once.
        let accept = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'cueList.review.' AND identifier ENDSWITH %@", EditorCommand.acceptChange.id)
        ).firstMatch
        accept.click()
        waitForValue(of: app.cueCells(.text).firstMatch, toEqual: "Hello there. How are you?")
        waitForValue(of: review, toEqual: "Transcription: 1 change to review")
        button(.acceptAllChanges, in: app).click()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: review)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "The review stays after Accept All")
        XCTAssertEqual(app.cueCells(.text).count, 2)
        XCTAssertEqual(app.cueCells(.text).element(boundBy: 1).value as? String, "Fine, thanks.")
    }

    @MainActor
    func testTranslationGuessesTheAddresseeAndSwapsInOneClick() throws {
        let app = launchApp(source: "translation-source-23.976.srt")
        XCTAssertTrue(app.cueCells(.source).firstMatch.waitForExistence(timeout: 10), "No source cells")
        chooseAIMenuItem(.translateWithAI, in: app)

        let review = app.descendants(matching: .any)[AccessibilityID.CueList.aiReview]
        XCTAssertTrue(review.waitForExistence(timeout: 20), "No review after translating")
        waitForValue(of: review, toEqual: "Translation: 3 changes to review")
        let proposal = app.cueCells(.proposal).firstMatch
        XCTAssertEqual(proposal.value as? String, "[ar] Where are you going? ♀")
        button(.acceptAllChanges, in: app).click()

        let text = app.cueCells(.text).element(boundBy: 0)
        waitForValue(of: text, toEqual: "[ar] Where are you going? ♀")
        // The unsure guess is flagged; one click on its chip picks another addressee's wording.
        let chip = app.cueCells(.addressee).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "No addressee chip")
        XCTAssertEqual(chip.value as? String, "female")
        chip.click()
        let male = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'cueList.row.' AND identifier ENDSWITH '.addressee.male'")
        ).firstMatch
        XCTAssertTrue(male.waitForExistence(timeout: 10), "No addressee menu")
        male.click()
        waitForValue(of: text, toEqual: "[ar] Where are you going? ♂")
        waitForValue(of: chip, toEqual: "male")
    }
}
