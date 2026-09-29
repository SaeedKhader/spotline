import EditorCommands
import SpotlineAccessibility
import XCTest

extension XCTestCase {
    @MainActor
    func launchApp(
        openFixture: Bool = true,
        openSubtitles: Bool = false,
        media: String = "testsrc-23.976.mp4",
        subtitles: String = "testsrc-23.976.srt",
        source: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMode", "-ApplePersistenceIgnoreState", "YES"]
        if openFixture {
            let fixture = Bundle(for: MainWindowUITests.self).url(forResource: media, withExtension: nil)
            app.launchArguments += ["-OpenMedia", fixture!.path]
        }
        if openSubtitles {
            let fixture = Bundle(for: MainWindowUITests.self).url(forResource: subtitles, withExtension: nil)
            app.launchArguments += ["-OpenSubtitles", fixture!.path]
        }
        if let source {
            let fixture = Bundle(for: MainWindowUITests.self).url(forResource: source, withExtension: nil)
            app.launchArguments += ["-OpenSource", fixture!.path]
        }
        app.launch()
        app.activate()
        // The editor window must appear at launch without being asked for.
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 10),
            "No editor window at launch. Accessibility hierarchy:\n\(app.debugDescription)"
        )
        return app
    }

    /// The button for `command`, once it exists and is enabled (media has loaded).
    @MainActor
    func button(_ command: EditorCommand, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[AccessibilityID.command(command.id)]
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"), object: button
        )
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 10), .completed, "\(command.id) never became enabled")
        return button
    }

    /// Waits for an element's accessibility value to become `expected`.
    @MainActor
    func waitForValue(
        of element: XCUIElement,
        toEqual expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: element)
        let result = XCTWaiter().wait(for: [match], timeout: 10)
        let actual = element.value as? String ?? "nil"
        XCTAssertEqual(result, .completed, "Expected \(expected), got \(actual)", file: file, line: line)
    }
}

extension XCUIApplication {
    /// The cells of one cue list column, in row order.
    func cueCells(_ column: AccessibilityID.CueList.Column) -> XCUIElementQuery {
        descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'cueList.row.' AND identifier ENDSWITH %@", ".\(column.rawValue)")
        )
    }

    var timecode: XCUIElement { staticTexts[AccessibilityID.Transport.timecode] }

    /// Timeline cue blocks, in cue order.
    var timelineCueBlocks: XCUIElementQuery {
        descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'timeline.cue.' AND NOT identifier ENDSWITH 'Handle'")
        )
    }

    /// Timeline cue edges (`.inHandle` or `.outHandle`), in cue order.
    func timelineHandles(_ suffix: String) -> XCUIElementQuery {
        descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'timeline.cue.' AND identifier ENDSWITH %@", suffix)
        )
    }
}
