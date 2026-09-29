import SpotlineAccessibility
import XCTest

/// Projects (`.spotline` packages): reopening one shows its cues and video, and
/// one whose video is gone still opens its cues.
final class ProjectUITests: XCTestCase {
    /// Writes a small project package: two cues, and a video at `mediaPath`.
    private func writeProject(named name: String, mediaPath: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ProjectUITests-\(UUID().uuidString)")
        let package = folder.appending(path: "\(name).spotline")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "formatVersion": 1,
            "frameRate": ["numerator": 24000, "denominator": 1001, "isDropFrame": false],
            "media": ["path": mediaPath, "isSecurityScoped": false],
            "qcPresetID": "netflix",
        ]
        func cue(_ text: String, from start: Int, to end: Int) -> [String: Any] {
            [
                "id": UUID().uuidString, "text": text, "position": "bottom", "isAIGenerated": true,
                "start": ["value": start, "timescale": 1], "end": ["value": end, "timescale": 1],
            ]
        }
        let subtitles: [String: Any] = [
            "id": UUID().uuidString, "languageCode": "en", "styles": [], "properties": [:], "speakers": [],
            "cues": [cue("Saved in the project", from: 1, to: 2), cue("Still here", from: 3, to: 4)],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: package.appending(path: "project.json"))
        try JSONSerialization.data(withJSONObject: subtitles).write(to: package.appending(path: "subtitles.json"))
        return package
    }

    @MainActor
    private func launch(project: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-OpenProject", project.path]
        return launchApp(openFixture: false, prepared: app)
    }

    @MainActor
    func testReopenedProjectShowsItsCuesAndVideo() throws {
        let fixture = try XCTUnwrap(Bundle(for: ProjectUITests.self).url(forResource: "testsrc-23.976.mp4", withExtension: nil))
        let app = launch(project: try writeProject(named: "Pilot", mediaPath: fixture.path))
        let texts = app.cueCells(.text)
        XCTAssertTrue(texts.firstMatch.waitForExistence(timeout: 10), "No cue rows")
        XCTAssertEqual(texts.count, 2)
        XCTAssertEqual(texts.element(boundBy: 0).value as? String, "Saved in the project")
        waitForValue(of: app.staticTexts[AccessibilityID.Transport.frameRate], toEqual: "23.976 fps")
        XCTAssertTrue(app.windows["Pilot"].exists, "The window is named after the project")
    }

    @MainActor
    func testProjectWithAMissingVideoStillOpensItsCues() throws {
        let app = launch(project: try writeProject(named: "Moved", mediaPath: "/Volumes/Gone/Moved.mov"))
        // Spotline asks where the video went; the cues open either way.
        let withoutVideo = app.buttons["Open Without Video"]
        XCTAssertTrue(withoutVideo.waitForExistence(timeout: 10), "No prompt to locate the video")
        withoutVideo.click()
        let texts = app.cueCells(.text)
        XCTAssertTrue(texts.firstMatch.waitForExistence(timeout: 10), "No cue rows")
        XCTAssertEqual(texts.count, 2)
        let empty = app.descendants(matching: .any)[AccessibilityID.Video.emptyState]
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        XCTAssertTrue((empty.value as? String ?? "").contains("relink"), "The empty video says how to relink")
    }
}
