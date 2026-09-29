import EditorCommands
import SpotlineAccessibility
import XCTest

/// Importing a styled ASS file, the QC summary and the issues panel.
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
    func testIssuesPanelListsIssuesAndSelectsCues() throws {
        let app = launchApp(openSubtitles: true, subtitles: "styled-23.976.ass")
        _ = button(EditorCommand.stepForward, in: app)
        waitForValue(of: app.descendants(matching: .any)[AccessibilityID.CueList.reviewSummary], toEqual: "2 cues need review")
        waitForValue(of: app.descendants(matching: .any)[AccessibilityID.Issues.preset], toEqual: "Netflix (Adult)")

        // Review › Show Issues (Option-Command-I).
        app.typeKey("i", modifierFlags: [.command, .option])
        let items = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'issues.item.'"))
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 10), "No issues listed")
        // Cue 3: too long a line, too fast, too short. Cue 4: no text.
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items.element(boundBy: 3).value as? String, "No text")

        items.element(boundBy: 3).click()
        waitForValue(of: app.timecode, toEqual: "00:00:03:00")

        // Previous Cue with Issues goes back to cue 3 (2 s).
        app.typeKey(.upArrow, modifierFlags: [.command, .option])
        waitForValue(of: app.timecode, toEqual: "00:00:02:00")
    }
}
