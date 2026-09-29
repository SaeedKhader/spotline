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

    @Test func typingKeysConflictWithTextEditing() {
        #expect(EditorCommand.setIn.defaultShortcut!.conflictsWithTextEditing)
        #expect(EditorCommand.togglePlay.defaultShortcut!.conflictsWithTextEditing)
        #expect(!EditorCommand.nextCue.defaultShortcut!.conflictsWithTextEditing, "Moves between cues while typing")
        #expect(EditorCommand.shuttleForward.defaultShortcut!.conflictsWithTextEditing)
        #expect(EditorCommand.goToStart.defaultShortcut!.conflictsWithTextEditing)
        #expect(EditorCommand.goToEnd.defaultShortcut!.conflictsWithTextEditing)
        #expect(!EditorCommand.transcribe.defaultShortcut!.conflictsWithTextEditing)
        #expect(EditorCommand.deleteCue.defaultShortcut!.conflictsWithTextEditing)
        #expect(!EditorCommand.undo.defaultShortcut!.conflictsWithTextEditing)
        #expect(!EditorCommand.addCue.defaultShortcut!.conflictsWithTextEditing)
    }
}
