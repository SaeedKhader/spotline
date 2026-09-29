import EditorCommands
import SpotlineAccessibility
import XCTest

/// Importing subtitles, the cue list (each row edits its cue), in/out at the playhead and undo.
final class EditingUITests: XCTestCase {
    @MainActor
    func testImportedCuesFillTheList() throws {
        let app = launchApp(openSubtitles: true)
        let texts = app.cueCells(.text)
        XCTAssertTrue(texts.firstMatch.waitForExistence(timeout: 10), "No cue rows")
        XCTAssertEqual(texts.count, 3)
        XCTAssertEqual(texts.element(boundBy: 1).value as? String, "Second cue\nwith two lines")
        XCTAssertEqual(texts.element(boundBy: 2).value as? String, "<i>Third cue</i>")
        // 0.5 s at 23.976 fps first shows on frame 12.
        XCTAssertEqual(app.cueCells(.inPoint).element(boundBy: 0).value as? String, "00:00:00:12")
    }

    @MainActor
    func testSelectingACueSeeksAndShowsItOverTheVideo() throws {
        let app = launchApp(openSubtitles: true)
        _ = button(EditorCommand.stepForward, in: app)
        app.cueCells(.number).element(boundBy: 1).click()

        waitForValue(of: app.timecode, toEqual: "00:00:02:00")
        waitForValue(of: app.staticTexts[AccessibilityID.Video.subtitle], toEqual: "Second cue\nwith two lines")
        waitForValue(of: app.cueCells(.inPoint).element(boundBy: 1), toEqual: "00:00:02:00")
        waitForValue(of: app.cueCells(.outPoint).element(boundBy: 1), toEqual: "00:00:03:00")
    }

    @MainActor
    func testAddCueTypeTextAndUndo() throws {
        let app = launchApp()
        let stepForward = button(EditorCommand.stepForward, in: app)
        for _ in 0..<5 { stepForward.click() }
        waitForValue(of: app.timecode, toEqual: "00:00:00:05")

        // Add Cue at Playhead, Shift-Command-N, puts the cursor in the new row's text.
        app.typeKey("n", modifierFlags: [.command, .shift])
        let textEditor = app.cueCells(.text).firstMatch
        XCTAssertTrue(textEditor.waitForExistence(timeout: 10))
        waitForValue(of: app.cueCells(.inPoint).firstMatch, toEqual: "00:00:00:05")

        // Letters and Space that are also shortcuts (Set In, Set Out, Play, J/K/L) must type.
        app.typeText("Is it on? jkl")
        waitForValue(of: textEditor, toEqual: "Is it on? jkl")
        waitForValue(of: app.timecode, toEqual: "00:00:00:05")

        // The typing undoes as one step, then the new cue.
        app.typeKey("z", modifierFlags: .command)
        waitForValue(of: textEditor, toEqual: "")
        XCTAssertEqual(app.cueCells(.number).count, 1)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.buttons[AccessibilityID.command(EditorCommand.importSubtitles.id)].waitForExistence(timeout: 10))
        XCTAssertEqual(app.cueCells(.number).count, 0)

        app.typeKey("z", modifierFlags: [.command, .shift])
        waitForValue(of: app.cueCells(.inPoint).firstMatch, toEqual: "00:00:00:05")
    }

    @MainActor
    func testSetInAndOutAtPlayheadWithShortcuts() throws {
        let app = launchApp(openSubtitles: true)
        _ = button(EditorCommand.stepForward, in: app)
        app.cueCells(.number).element(boundBy: 0).click()
        waitForValue(of: app.timecode, toEqual: "00:00:00:12")

        for _ in 0..<3 { app.typeKey(.rightArrow, modifierFlags: []) }
        waitForValue(of: app.timecode, toEqual: "00:00:00:15")
        app.typeKey("i", modifierFlags: [])
        waitForValue(of: app.cueCells(.inPoint).firstMatch, toEqual: "00:00:00:15")

        for _ in 0..<15 { app.typeKey(.rightArrow, modifierFlags: []) }
        waitForValue(of: app.timecode, toEqual: "00:00:01:06")
        app.typeKey("o", modifierFlags: [])
        waitForValue(of: app.cueCells(.outPoint).firstMatch, toEqual: "00:00:01:06")

        app.typeKey("z", modifierFlags: .command)
        waitForValue(of: app.cueCells(.outPoint).firstMatch, toEqual: "00:00:01:12")
        app.typeKey("z", modifierFlags: .command)
        waitForValue(of: app.cueCells(.inPoint).firstMatch, toEqual: "00:00:00:12")
    }

    @MainActor
    func testNextCueFromTheKeyboard() throws {
        let app = launchApp(openSubtitles: true)
        _ = button(EditorCommand.stepForward, in: app)
        app.typeKey(.downArrow, modifierFlags: .command)
        waitForValue(of: app.timecode, toEqual: "00:00:00:12")
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeKey(.downArrow, modifierFlags: .command)
        // 3.5 s first shows on frame 84.
        waitForValue(of: app.timecode, toEqual: "00:00:03:12")
        waitForValue(of: app.staticTexts[AccessibilityID.Video.subtitle], toEqual: "Third cue")
    }
}
