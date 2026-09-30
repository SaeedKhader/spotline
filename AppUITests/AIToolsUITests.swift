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

        // A cloud translator gets a reasoning effort, medium unless changed.
        let effort = app.popUpButtons[AccessibilityID.AISettings.reasoningEffort]
        XCTAssertTrue(effort.waitForExistence(timeout: 10), "No reasoning effort for Luna")
        waitForValue(of: effort, toEqual: "Medium")
        effort.click()
        let low = app.menuItems["Low (fastest)"]
        XCTAssertTrue(low.waitForExistence(timeout: 10))
        low.click()
        waitForValue(of: effort, toEqual: "Low (fastest)")
    }

    @MainActor
    func testWallaIsLeftOutUnlessTurnedOff() throws {
        let app = launchApp()
        app.typeKey(",", modifierFlags: .command)
        let aiTab = app.toolbars.buttons["AI"]
        XCTAssertTrue(aiTab.waitForExistence(timeout: 10), "No AI tab in Settings")
        aiTab.click()

        let walla = app.descendants(matching: .any)[AccessibilityID.AISettings.leavesOutWalla]
        XCTAssertTrue(walla.waitForExistence(timeout: 10), "No setting for crowd chatter")
        XCTAssertEqual(walla.value as? Int, 1, "Crowd chatter is left out in a fresh app")
        walla.click()
        expectation(for: NSPredicate(format: "value == 0"), evaluatedWith: walla)
        waitForExpectations(timeout: 10)
    }

    @MainActor
    func testMadeUpLanguagesAreLeftOutUnlessTurnedOff() throws {
        let app = launchApp()
        app.typeKey(",", modifierFlags: .command)
        let aiTab = app.toolbars.buttons["AI"]
        XCTAssertTrue(aiTab.waitForExistence(timeout: 10), "No AI tab in Settings")
        aiTab.click()

        let madeUp = app.descendants(matching: .any)[AccessibilityID.AISettings.leavesOutFictionalLanguages]
        XCTAssertTrue(madeUp.waitForExistence(timeout: 10), "No setting for made-up languages")
        XCTAssertEqual(madeUp.value as? Int, 1, "Made-up languages are left out in a fresh app")
        madeUp.click()
        expectation(for: NSPredicate(format: "value == 0"), evaluatedWith: madeUp)
        waitForExpectations(timeout: 10)
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
        // The AI bar says what the transcription did once it is done.
        let done = app.descendants(matching: .any)[AccessibilityID.CueList.aiSummary]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "No summary after transcribing")
        waitForValue(of: done, toEqual: "2 cues transcribed")
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
        let done = app.descendants(matching: .any)[AccessibilityID.CueList.aiSummary]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "No summary after translating")
        let flagged = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value ENDSWITH ' · 2 flagged'"), object: done)
        XCTAssertEqual(XCTWaiter().wait(for: [flagged], timeout: 10), .completed, "The summary does not count the flagged lines")
        // Both lines read more than one way: a choice card each in the review sidebar.
        let summary = app.descendants(matching: .any)[AccessibilityID.CueList.choicesSummary]
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "No choices filter")
        waitForValue(of: summary, toEqual: "2 lines to choose")
        let cards = app.reviewCards(".choice")

        // The Choices filter lists only them; one click on a reading uses it.
        summary.click()
        let reviewing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: summary)
        XCTAssertEqual(XCTWaiter().wait(for: [reviewing], timeout: 10), .completed, "No filter")
        XCTAssertEqual(cards.count, 2)
        let male = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'review.card.' AND identifier ENDSWITH '.choice.variant.1'")
        ).firstMatch
        XCTAssertTrue(male.waitForExistence(timeout: 10), "No readings")
        male.click()
        waitForValue(of: summary, toEqual: "1 line to choose")

        // Accepting the rest keeps the translator's pick; the filter goes with the last choice.
        chooseAIMenuItem(.acceptRemainingChoices, in: app)
        let ended = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: summary)
        XCTAssertEqual(XCTWaiter().wait(for: [ended], timeout: 10), .completed, "Choices remain")
        waitForValue(of: texts.element(boundBy: 0), toEqual: "[ar] Where are you going? ♂")
        // The short last line was joined to the one before once the translation was in (M11).
        waitForValue(of: texts.element(boundBy: 1), toEqual: "[ar] Where are you going, John? ♀\n[ar] First cue")
        XCTAssertEqual(texts.count, 2)
        XCTAssertEqual(cards.count, 0)
    }

    @MainActor
    func testReviewCardsAreDecidedWithTheKeyboardAndUndone() throws {
        let app = launchApp(source: "translation-source-23.976.srt")
        XCTAssertTrue(app.cueCells(.source).firstMatch.waitForExistence(timeout: 10), "No source cells")
        chooseAIMenuItem(.translateWithAI, in: app)
        let texts = app.cueCells(.text)
        waitForValue(of: texts.element(boundBy: 0), toEqual: "[ar] Where are you going? ♀")
        let summary = app.descendants(matching: .any)[AccessibilityID.CueList.choicesSummary]
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "No choices filter")
        summary.click()
        let cards = app.reviewCards(".choice")
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 10), "No choice cards")

        // Clicking a card (its header, above the readings) selects its cue and gives the sidebar the keys;
        // 2 tries the second reading, and the card stays until Return confirms it.
        cards.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)).click()
        app.typeKey("2", modifierFlags: [])
        waitForValue(of: texts.element(boundBy: 0), toEqual: "[ar] Where are you going? ♂")
        waitForValue(of: summary, toEqual: "1 line to choose")
        XCTAssertEqual(cards.count, 2, "The card stays until confirmed")
        app.typeKey(.return, modifierFlags: [])
        let confirmed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 1"), object: cards)
        XCTAssertEqual(XCTWaiter().wait(for: [confirmed], timeout: 10), .completed, "Confirm did not settle the card")

        // The note offers Undo, which lists the card again (the reading still in); ⌘Z takes the reading back.
        let undo = app.buttons[AccessibilityID.Review.undoButton]
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "No Undo after deciding")
        undo.click()
        let reopened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: cards)
        XCTAssertEqual(XCTWaiter().wait(for: [reopened], timeout: 10), .completed, "Undo did not list the card again")
        XCTAssertEqual(texts.element(boundBy: 0).value as? String, "[ar] Where are you going? ♂")
        app.typeKey("z", modifierFlags: .command)
        waitForValue(of: texts.element(boundBy: 0), toEqual: "[ar] Where are you going? ♀")
        waitForValue(of: summary, toEqual: "2 lines to choose")

        // Return keeps the translator's pick and moves on; the next Return settles the last.
        cards.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)).click()
        app.typeKey(.return, modifierFlags: [])
        waitForValue(of: summary, toEqual: "1 line to choose")
        app.typeKey(.return, modifierFlags: [])
        let ended = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: summary)
        XCTAssertEqual(XCTWaiter().wait(for: [ended], timeout: 10), .completed, "Choices remain")
        waitForValue(of: texts.element(boundBy: 0), toEqual: "[ar] Where are you going? ♀")
    }

    @MainActor
    func testClearTranslationEmptiesTheTargetInOneUndoStep() throws {
        let app = launchApp(source: "translation-source-23.976.srt")
        XCTAssertTrue(app.cueCells(.source).firstMatch.waitForExistence(timeout: 10), "No source cells")
        chooseAIMenuItem(.translateWithAI, in: app)
        let texts = app.cueCells(.text)
        waitForValue(of: texts.element(boundBy: 0), toEqual: "[ar] Where are you going? ♀")
        let summary = app.descendants(matching: .any)[AccessibilityID.CueList.choicesSummary]
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "No choices filter")

        chooseAIMenuItem(.clearTranslation, in: app)
        waitForValue(of: texts.element(boundBy: 0), toEqual: "")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: summary)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "Choices stayed after clearing")
        // The source stays, ready to translate again.
        XCTAssertEqual(app.cueCells(.source).firstMatch.value as? String, "Where are you going?")

        app.typeKey("z", modifierFlags: .command)
        waitForValue(of: texts.element(boundBy: 0), toEqual: "[ar] Where are you going? ♀")
    }

    @MainActor
    func testClearTranscriptAsksThenRemovesTheCuesInOneUndoStep() throws {
        let app = launchApp()
        _ = button(.stepForward, in: app)
        chooseAIMenuItem(.transcribe, in: app)
        let texts = app.cueCells(.text)
        let second = texts.element(boundBy: 1)
        XCTAssertTrue(second.waitForExistence(timeout: 20), "The second cue never came")
        waitForValue(of: second, toEqual: "Fine, thanks.")

        chooseAIMenuItem(.clearTranscript, in: app)
        // It asks first: the next transcription is paid for again.
        let confirm = app.buttons["Clear Transcript"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "No confirmation")
        confirm.click()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"), object: texts)
        XCTAssertEqual(XCTWaiter().wait(for: [cleared], timeout: 10), .completed, "Cues stayed after clearing")

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(second.waitForExistence(timeout: 10), "Undo did not bring the cues back")
        waitForValue(of: second, toEqual: "Fine, thanks.")
    }
}
