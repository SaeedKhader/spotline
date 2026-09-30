import EditorCommands
import SpotlineAccessibility
import XCTest

/// Importing a styled ASS file, and reviewing QC issues in the review sidebar's Issues filter.
final class ReviewUITests: XCTestCase {
    @MainActor
    func testImportsStyledASS() throws {
        let app = launchApp(openSubtitles: true, subtitles: "styled-23.976.ass")
        let texts = app.cueCells(.text)
        XCTAssertTrue(texts.firstMatch.waitForExistence(timeout: 10), "No cue rows")
        XCTAssertEqual(texts.count, 4)
        // ASS override tags become the editor's markup.
        XCTAssertEqual(texts.element(boundBy: 0).value as? String, "<i>First cue</i>")
        XCTAssertEqual(texts.element(boundBy: 1).value as? String, "EXIT")

        // The Sign style is top-aligned: at 1 s it shows at the top, over the first cue.
        _ = button(EditorCommand.stepForward, in: app)
        app.cueCells(.number).element(boundBy: 1).click()
        waitForValue(of: app.staticTexts[AccessibilityID.Video.topSubtitle], toEqual: "EXIT")
        waitForValue(of: app.staticTexts[AccessibilityID.Video.subtitle], toEqual: "First cue")
    }

    @MainActor
    func testIssuesFilterListsCardsAndSelectsCues() throws {
        let app = launchApp(openSubtitles: true, subtitles: "styled-23.976.ass")
        _ = button(EditorCommand.stepForward, in: app)
        // The review sidebar shows by itself while there is something to review.
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.Review.root].waitForExistence(timeout: 10), "No review sidebar")
        waitForValue(of: app.descendants(matching: .any)[AccessibilityID.CueList.reviewSummary], toEqual: "2 cues need review")

        // Review › Review Issues (Option-Command-I): a card per cue with issues; the cue list keeps every cue.
        app.typeKey("i", modifierFlags: [.command, .option])
        waitForValue(of: app.descendants(matching: .any)[AccessibilityID.Issues.preset], toEqual: "Netflix (Adult)")
        XCTAssertEqual(app.cueCells(.text).count, 4)
        let cards = app.reviewCards(".issues")
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 10), "No issue cards")
        // Cue 3: too long a line, too fast, too short. Cue 4: no text.
        XCTAssertEqual(cards.count, 2)
        XCTAssertTrue(cards.element(boundBy: 1).staticTexts["No text"].exists, "Cue 4's card does not say it has no text")

        // The card's header, above its options (a click on an option would try it).
        cards.element(boundBy: 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).click()
        waitForValue(of: app.timecode, toEqual: "00:00:03:00")
        // Its one suggestion: delete the empty cue (Return, or 1).
        let suggestion = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'review.card.' AND identifier ENDSWITH '.issues.suggestion.0'")
        ).element(boundBy: 1)
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10), "No suggestion on the empty cue's card")
        XCTAssertEqual(suggestion.label, "Delete the Cue")

        // Previous Cue to Review goes back to cue 3's card (2 s).
        app.typeKey(.upArrow, modifierFlags: [.command, .option])
        waitForValue(of: app.timecode, toEqual: "00:00:02:00")

        // The title bar button counts what is left and hides the sidebar; View › Show Review
        // (Option-Command-0) shows it again.
        let toggle = app.descendants(matching: .any)[AccessibilityID.Review.toggle]
        waitForValue(of: toggle, toEqual: "2 to review")
        toggle.click()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: cards.firstMatch)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "The sidebar stayed")
        app.typeKey("0", modifierFlags: [.command, .option])
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 10), "The sidebar did not come back")
    }

    @MainActor
    func testAnIssueIsFixedRightInItsCard() throws {
        let app = launchApp(openSubtitles: true, subtitles: "styled-23.976.ass")
        _ = button(EditorCommand.stepForward, in: app)
        let cards = app.reviewCards(".issues")
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 10), "No issue cards")
        XCTAssertEqual(cards.count, 2)

        // Cue 4 has no text: Edit opens its text (and timing) in the card; ⌘Return finishes.
        let edit = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'review.card.' AND identifier ENDSWITH '.issues.edit'")
        ).element(boundBy: 1)
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "No Edit on the card")
        edit.click()
        let text = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'review.card.' AND identifier ENDSWITH '.issues.text'")
        ).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10), "No text in the card")
        app.typeText("Goodbye")
        waitForValue(of: app.cueCells(.text).element(boundBy: 3), toEqual: "Goodbye")
        app.typeKey(.return, modifierFlags: .command)
        let fixed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 1"), object: cards)
        XCTAssertEqual(XCTWaiter().wait(for: [fixed], timeout: 10), .completed, "The card stayed after the fix")
    }

    /// The styled fixture's first cue (bottom, 0.5–1.5 s) and the EXIT sign (top, 1–2.5 s) overlap.
    @MainActor
    func testTopAndBottomCuesOnScreenTogetherStackOnTheTimeline() throws {
        let app = launchApp(openSubtitles: true, subtitles: "styled-23.976.ass")
        let blocks = app.timelineCueBlocks
        XCTAssertTrue(blocks.firstMatch.waitForExistence(timeout: 10))
        let bottom = blocks.element(boundBy: 0).frame
        let top = blocks.element(boundBy: 1).frame
        XCTAssertFalse(bottom.intersects(top), "The sign's block hides the dialogue's: \(top) over \(bottom)")
        XCTAssertLessThan(top.maxY, bottom.minY + 1, "The top cue's block is above the bottom cue's")
    }
}
