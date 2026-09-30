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
    func testSettingsOfferLunaForTranslationAndSayWhatItNeeds() throws {
        let app = launchApp()
        app.typeKey(",", modifierFlags: .command)
        let aiTab = app.toolbars.buttons["AI"]
        XCTAssertTrue(aiTab.waitForExistence(timeout: 10), "No AI tab in Settings")
        aiTab.click()

        let picker = app.popUpButtons[AccessibilityID.AISettings.translationProvider]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "No translation provider picker")
        picker.click()
        let luna = app.menuItems["OpenAI GPT-6 Luna (cloud, cheapest)"]
        XCTAssertTrue(luna.waitForExistence(timeout: 10), "Luna is not offered")
        luna.click()

        // Cloud is off in a fresh app, so the choice says what it needs first.
        let problem = app.descendants(matching: .any)[AccessibilityID.AISettings.providerProblem]
        XCTAssertTrue(problem.waitForExistence(timeout: 10))
        waitForValue(of: problem, toEqual: "OpenAI GPT-6 Luna needs Allow cloud providers turned on.")
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
    func testTranslationFlagsLinesAndAPickSwapsInOneClick() throws {
        let app = launchApp(source: "translation-source-23.976.srt")
        XCTAssertTrue(app.cueCells(.source).firstMatch.waitForExistence(timeout: 10), "No source cells")
        chooseAIMenuItem(.translateWithAI, in: app)

        let texts = app.cueCells(.text)
        waitForValue(of: texts.element(boundBy: 0), toEqual: "[ar] Where are you going? ♀")
        XCTAssertFalse(app.descendants(matching: .any)[AccessibilityID.CueList.aiReview].exists, "Translation is not reviewed")
        // Both lines read more than one way; each shows its variants.
        let summary = app.descendants(matching: .any)[AccessibilityID.CueList.choicesSummary]
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "No choices summary")
        waitForValue(of: summary, toEqual: "2 lines to choose")
        XCTAssertEqual(app.cueCells(.choices).count, 2)

        // The review shows only those lines; one click on a variant uses it.
        summary.click()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.CueList.choiceReview].waitForExistence(timeout: 10), "No review")
        let male = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'cueList.row.' AND identifier ENDSWITH '.choices.1'")
        ).firstMatch
        XCTAssertTrue(male.waitForExistence(timeout: 10), "No variants")
        male.click()
        waitForValue(of: summary, toEqual: "1 line to choose")

        // Accepting the rest keeps the translator's pick and ends the review.
        chooseAIMenuItem(.acceptRemainingChoices, in: app)
        let ended = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: summary)
        XCTAssertEqual(XCTWaiter().wait(for: [ended], timeout: 10), .completed, "Choices remain")
        waitForValue(of: texts.element(boundBy: 0), toEqual: "[ar] Where are you going? ♂")
        waitForValue(of: texts.element(boundBy: 1), toEqual: "[ar] Where are you going, John? ♀")
        XCTAssertEqual(app.cueCells(.choices).count, 0)
    }
}
