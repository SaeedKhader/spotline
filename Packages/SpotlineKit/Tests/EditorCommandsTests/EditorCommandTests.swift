import Testing
@testable import EditorCommands

struct EditorCommandTests {
    @Test func commandIDsAreUnique() {
        let ids = EditorCommand.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func commandsAreFoundByID() {
        #expect(EditorCommand.named("playback.stepForward") == .stepForward)
        #expect(EditorCommand.named("nope") == nil)
    }

    @Test func shortcutsAreUnique() {
        let shortcuts = EditorCommand.all.compactMap(\.defaultShortcut)
        #expect(Set(shortcuts).count == shortcuts.count)
    }
}
