import EditorCommands
import SpotlineAccessibility
import XCTest

/// AI tools with scripted providers (UI test mode): transcription and translation
/// go straight into the cue list, one undo step per batch.
final class AIToolsUITests: XCTestCase {
    @MainActor
    func chooseAIMenuItem(_ command: EditorCommand, in app: XCUIApplication) {
        app.menuBars.menuBarItems["AI"].click()
        let item = app.menuBars.menuItems[command.title]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "No \(command.title) menu item")
        item.click()
    }

    @MainActor
    func testTranscriptionFillsTheCueList() throws {
        let app = launchApp()
        _ = button(.stepForward, in: app)
        chooseAIMenuItem(.transcribe, in: app)

        let texts = app.cueCells(.text)
        XCTAssertTrue(texts.firstMatch.waitForExistence(timeout: 20), "No cues after transcribing")
        waitForValue(of: texts.element(boundBy: 0), toEqual: "Hello there. How are you?")
        let second = texts.element(boundBy: 1)
        XCTAssertTrue(second.waitForExistence(timeout: 20), "The second cue never came")
        waitForValue(of: second, toEqual: "Fine, thanks.")
        XCTAssertFalse(app.descendants(matching: .any)[AccessibilityID.CueList.aiReview].exists, "Transcription is not reviewed")
        // One undo removes the last batch.
        app.typeKey("z", modifierFlags: .command)
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: second)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "Undo did not remove the last cue")
        XCTAssertEqual(texts.count, 1)
    }

    @MainActor
    func testTranslationGuessesTheAddresseeAndSwapsInOneClick() throws {
        let app = launchApp(source: "translation-source-23.976.srt")
        XCTAssertTrue(app.cueCells(.source).firstMatch.waitForExistence(timeout: 10), "No source cells")
        chooseAIMenuItem(.translateWithAI, in: app)

        let text = app.cueCells(.text).element(boundBy: 0)
        waitForValue(of: text, toEqual: "[ar] Where are you going? ♀")
        XCTAssertFalse(app.descendants(matching: .any)[AccessibilityID.CueList.aiReview].exists, "Translation is not reviewed")
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
