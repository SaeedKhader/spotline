import EditorCommands
import SpotlineAccessibility
import XCTest

/// Translation mode (source beside target, translation memory, glossary) and EBU STL import.
final class TranslationUITests: XCTestCase {
    @MainActor
    func testSourceShowsBesideAnEmptyTarget() throws {
        let app = launchApp(source: "translation-source-23.976.srt")
        let sources = app.cueCells(.source)
        XCTAssertTrue(sources.firstMatch.waitForExistence(timeout: 10), "No source cells")
        XCTAssertEqual(sources.count, 3)
        XCTAssertEqual(sources.element(boundBy: 1).value as? String, "Where are you going, John?")
        XCTAssertEqual(app.cueCells(.text).element(boundBy: 0).value as? String, "")
        // Every cue still needs translating.
        waitForValue(of: app.descendants(matching: .any)[AccessibilityID.CueList.reviewSummary], toEqual: "3 cues need review")
    }

    @MainActor
    func testTranslationMemorySuggestsTheLastTranslation() throws {
        let app = launchApp(source: "translation-source-23.976.srt")
        let texts = app.cueCells(.text)
        XCTAssertTrue(texts.firstMatch.waitForExistence(timeout: 10), "No cue rows")
        texts.element(boundBy: 0).click()
        app.typeText("Ou vas-tu ?")
        waitForValue(of: texts.element(boundBy: 0), toEqual: "Ou vas-tu ?")

        // Moving to the next cue stores the translation and suggests it there (4 of 5 words match).
        app.typeKey(.downArrow, modifierFlags: .command)
        let match = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'cueList.row.' AND identifier ENDSWITH '.memory.0'"))
            .firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 10), "No memory suggestion")
        XCTAssertEqual(match.value as? String, "Ou vas-tu ?")
        // Rows grow and shrink with hover; let the layout settle under the mouse before clicking.
        match.hover()
        match.click()
        waitForValue(of: texts.element(boundBy: 1), toEqual: "Ou vas-tu ?")
    }

    @MainActor
    func testGlossaryTermsShowOnMatchingCues() throws {
        let app = launchApp(source: "translation-source-23.976.srt")
        XCTAssertTrue(app.cueCells(.source).firstMatch.waitForExistence(timeout: 10), "No source cells")
        // Translation › Show Glossary (Option-Command-G), then add a term.
        app.typeKey("g", modifierFlags: [.command, .option])
        let add = app.buttons[AccessibilityID.Glossary.addEntry]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "No glossary panel")
        add.click()
        let source = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'glossary.entry.' AND identifier ENDSWITH '.source'"))
            .firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10), "No glossary row")
        source.click()
        app.typeText("John")

        // Cue 2's source says "John": its row shows the term (whether the target uses it is unit tested).
        let chip = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'cueList.row.' AND identifier ENDSWITH '.glossary.0'"))
            .firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "No glossary term on the cue")
        XCTAssertEqual(chip.label, "John")
    }

    @MainActor
    func testImportsArabicEBUSTL() throws {
        let app = launchApp(openSubtitles: true, subtitles: "arabic-25.stl")
        let texts = app.cueCells(.text)
        XCTAssertTrue(texts.firstMatch.waitForExistence(timeout: 10), "No cue rows")
        XCTAssertEqual(texts.count, 3)
        let values = (0..<texts.count).compactMap { texts.element(boundBy: $0).value as? String }
        XCTAssertEqual(values.first, "إلى أين أنت ذاهب؟")
        XCTAssertEqual(Set(values.dropFirst()), ["<i>مرحباً</i>\nيا جون", "مخرج"])
        // The sign reads as a top cue: at 2 s it shows at the top.
        _ = button(EditorCommand.stepForward, in: app)
        app.cueCells(.number).element(boundBy: 1).click()
        waitForValue(of: app.staticTexts[AccessibilityID.Video.topSubtitle], toEqual: "مخرج")
    }
}
