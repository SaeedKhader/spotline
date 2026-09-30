import EditorCommands
import SpotlineAccessibility
import XCTest

/// Importing a styled ASS file, and reviewing QC issues in the cue list's Issues scope.
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
    func testIssuesScopeListsIssuesAndSelectsCues() throws {
        let app = launchApp(openSubtitles: true, subtitles: "styled-23.976.ass")
        _ = button(EditorCommand.stepForward, in: app)
        waitForValue(of: app.descendants(matching: .any)[AccessibilityID.CueList.reviewSummary], toEqual: "2 cues need review")

        // Review › Review Issues (Option-Command-I): only the cues with issues, each with its issues.
        app.typeKey("i", modifierFlags: [.command, .option])
        waitForValue(of: app.descendants(matching: .any)[AccessibilityID.Issues.preset], toEqual: "Netflix (Adult)")
        XCTAssertEqual(app.cueCells(.text).count, 2)
        let items = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'issues.item.'"))
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 10), "No issues listed")
        // Cue 3: too long a line, too fast, too short. Cue 4: no text.
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items.element(boundBy: 3).value as? String, "No text")

        items.element(boundBy: 3).click()
        waitForValue(of: app.timecode, toEqual: "00:00:03:00")

        // Previous Cue to Review goes back to cue 3 (2 s).
        app.typeKey(.upArrow, modifierFlags: [.command, .option])
        waitForValue(of: app.timecode, toEqual: "00:00:02:00")
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
