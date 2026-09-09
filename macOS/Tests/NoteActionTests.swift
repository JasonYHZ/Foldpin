import AppKit
import Testing
@testable import FoldpinCore

@Test func paperShortcutsPreserveEditorAndSystemModifierCombinations() {
    #expect(NoteAction.matching(key: "k", modifiers: .command) == .actions)
    #expect(NoteAction.matching(key: "m", modifiers: .command) == .collapse)
    #expect(NoteAction.matching(key: "w", modifiers: .command) == .shelve)
    #expect(NoteAction.matching(key: "P", modifiers: [.command, .shift]) == .pin)
    #expect(NoteAction.matching(key: "C", modifiers: [.command, .shift, .capsLock]) == .copyAll)
    #expect(NoteAction.matching(key: "q", modifiers: .command) == nil)
    for (index, action) in NoteAction.colors.enumerated() {
        #expect(NoteAction.matching(key: String(index + 1), modifiers: .command) == action)
        #expect(action.noteColor == NoteColor.allCases[index])
    }
    for key in ["c", "v", "x", "z", "a", "b", "i", "/"] {
        #expect(NoteAction.matching(key: key, modifiers: .command) == nil)
    }
    #expect(NoteAction.matching(key: "v", modifiers: [.command, .shift, .option]) == nil)
    #expect(NoteAction.matching(key: "m", modifiers: [.command, .option]) == nil)
    #expect(NoteAction.matching(key: "k", modifiers: [.command, .control]) == nil)
    #expect(NoteAction.matching(key: "k", modifiers: []) == nil)
    #expect(NoteAction.matching(key: nil, modifiers: .command) == nil)
    #expect(NoteAction.matching(key: "", modifiers: .command) == nil)
}

@Test func paperActionHintsMatchUniqueExecutableShortcuts() {
    let actions = NoteAction.allCases.filter { !$0.key.isEmpty }
    #expect(Set(actions.map { $0.keycaps.joined() }).count == actions.count)
    for action in actions {
        #expect(NoteAction.matching(key: action.key, modifiers: action.modifiers) == action)
        #expect(action.keycaps.last == action.key.uppercased())
        #expect(action.heldHint == action.keycaps.filter { $0 != "⌘" }.joined())
    }
    #expect(NoteAction.shelveAll.keycaps.isEmpty)
}
