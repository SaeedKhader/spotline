import EditorCommands
import SpotlineAccessibility
import XCTest

/// Opening a video with subtitle tracks muxed in offers them for import.
final class EmbeddedSubtitlesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// embedded-subs.mkv: SubRip (default, stream 2), ASS (3), PGS (4, image-based) and French WebVTT (5).
    @MainActor
    func testOffersTheTracksAndImportsTheChosenOne() throws {
        let app = launchApp(media: "embedded-subs.mkv")
        let subRip = app.buttons[AccessibilityID.EmbeddedSubtitles.track(2)]
        XCTAssertTrue(subRip.waitForExistence(timeout: 10), "No offer to import. Hierarchy:\n\(app.debugDescription)")
        XCTAssertTrue(subRip.isSelected, "The default text track is chosen")
        XCTAssertFalse(app.buttons[AccessibilityID.EmbeddedSubtitles.track(4)].isEnabled, "PGS cannot be imported as text")

        app.buttons[AccessibilityID.EmbeddedSubtitles.track(5)].click()
        app.buttons[AccessibilityID.EmbeddedSubtitles.importButton].click()

        waitForValue(of: app.cueCells(.text).firstMatch, toEqual: "Bonjour")
        XCTAssertEqual(app.cueCells(.number).count, 2)
        XCTAssertFalse(subRip.exists, "The sheet closes after importing")
    }

    @MainActor
    func testNotNowThenImportFromTheFileMenu() throws {
        let app = launchApp(media: "embedded-subs.mkv")
        let cancel = app.buttons[AccessibilityID.EmbeddedSubtitles.cancelButton]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.click()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.cueCells(.number).count, 0)

        app.menuBars.menuItems[EditorCommand.importEmbeddedSubtitles.title].click()
        app.buttons[AccessibilityID.EmbeddedSubtitles.importButton].click()
        waitForValue(of: app.cueCells(.text).firstMatch, toEqual: "<i>Hello</i> from the\nembedded track")
    }

    @MainActor
    func testMediaWithoutSubtitleTracksOffersNothing() throws {
        let app = launchApp()
        _ = button(EditorCommand.stepForward, in: app)
        XCTAssertFalse(app.buttons[AccessibilityID.EmbeddedSubtitles.importButton].waitForExistence(timeout: 2))
    }
}
