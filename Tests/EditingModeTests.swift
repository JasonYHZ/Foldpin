import AppKit
import Testing
@testable import FoldpinCore

@MainActor private func modeEditor(_ content: NoteContent) -> PaperTextView {
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.isRichText = true
    editor.configure(content: content)
    return editor
}

@MainActor private final class ModeUndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}

@Test @MainActor func editingModeStartsEmptyAndRestoresSavedContentWithoutAddingCharacters() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = NoteFile(url: directory.appendingPathComponent("note.json"))
    let editor = modeEditor(try file.load().content)
    #expect(editor.string.isEmpty)
    #expect(editor.currentBlockKind == .paragraph)
    #expect(editor.typingAttributes[.backgroundColor] == nil)
    var document = NoteDocument()
    document.content = NoteContent(blocks: [NoteBlock(kind: .code, text: "let value = 1", language: .swift)])
    try file.save(document)
    editor.loadExternalContent(try file.load().content)
    #expect(editor.string == "let value = 1")
    #expect(editor.content == document.content)
    #expect(editor.currentBlockKind == .code)
}

@Test @MainActor func editingModeClearingCodeReturnsToParagraphAndSlashWorksWithUndo() {
    let original = NoteContent(blocks: [NoteBlock(kind: .code, text: "print(42)", language: .python)])
    let editor = modeEditor(original)
    let delegate = ModeUndoDelegate()
    delegate.history.groupsByEvent = false
    editor.delegate = delegate
    editor.allowsUndo = true
    var published = original
    editor.onContentChange = { published = $0 }
    editor.selectAll(nil)
    delegate.history.beginUndoGrouping()
    editor.deleteBackward(nil)
    delegate.history.endUndoGrouping()
    #expect(editor.string.isEmpty)
    #expect(editor.currentBlockKind == .paragraph)
    #expect(published.blocks[0].kind == .paragraph)
    #expect(editor.typingAttributes[.backgroundColor] == nil)
    delegate.history.undo()
    #expect(editor.content == original)
    delegate.history.redo()
    #expect(editor.string.isEmpty)
    #expect(editor.currentBlockKind == .paragraph)
    #expect(editor.typingAttributes[.backgroundColor] == nil)
    delegate.history.beginUndoGrouping()
    editor.insertText("/", replacementRange: editor.selectedRange())
    delegate.history.endUndoGrouping()
    #expect(editor.hasSlashSuggestions)
    #expect(editor.content.blocks[0].text == "/")
    #expect(editor.attributedString().attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
}

@Test @MainActor func editingModeMovingAcrossCodeBoundariesUsesDestinationFormatting() {
    let first = NoteBlock(kind: .code, text: "let a = 1", language: .swift)
    let middle = NoteBlock()
    let last = NoteBlock(kind: .code, text: "let b = 2", language: .swift)
    let editor = modeEditor(NoteContent(blocks: [first, middle, last]))
    var reportedKind: NoteBlockKind?
    editor.onBlockKindChange = { reportedKind = $0 }
    let middlePosition = (first.text as NSString).length + 1
    editor.setSelectedRange(NSRange(location: middlePosition, length: 0))
    #expect(reportedKind == .paragraph)
    #expect(editor.typingAttributes[.backgroundColor] == nil)
    editor.insertText("/", replacementRange: editor.selectedRange())
    #expect(editor.hasSlashSuggestions)
    #expect(editor.content.blocks.map(\.kind) == [.code, .paragraph, .code])
    #expect(editor.content.blocks[1].id == middle.id)
    #expect(editor.attributedString().attribute(.backgroundColor, at: middlePosition, effectiveRange: nil) == nil)
    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    #expect(reportedKind == .code)
    #expect(editor.typingAttributes[.foregroundColor] as? NSColor == GitHubCodeTheme.foreground)
    editor.insertText("/", replacementRange: editor.selectedRange())
    #expect(!editor.hasSlashSuggestions)
    #expect(editor.content.blocks[2].text == last.text + "/")
    editor.setSelectedRange(NSRange(location: middlePosition, length: 1))
    editor.insertPastedText("正文")
    #expect(editor.content.blocks[1].kind == .paragraph)
    #expect(editor.content.blocks[1].text == "正文")
    #expect(editor.attributedString().attribute(.backgroundColor, at: middlePosition, effectiveRange: nil) == nil)
    editor.perform(NSSelectorFromString("toggleBold:"), with: nil)
    editor.insertText("加粗", replacementRange: editor.selectedRange())
    #expect(editor.content.blocks[1].marks.contains { $0.bold && $0.location == 2 && $0.length == 2 })
}

@Test @MainActor func editingModeEmptyCodeBackspaceAndCommandReturnRestoreSlashEntry() throws {
    let editor = modeEditor(NoteContent(blocks: [NoteBlock(kind: .code)]))
    editor.deleteBackward(nil)
    #expect(editor.currentBlockKind == .paragraph)
    #expect(editor.string.isEmpty)
    editor.insertText("/", replacementRange: editor.selectedRange())
    #expect(editor.hasSlashSuggestions)

    let code = NoteBlock(kind: .code, text: "// keep this code", language: .swift)
    editor.configure(content: NoteContent(blocks: [code]))
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
        isARepeat: false, keyCode: 36))
    #expect(editor.performKeyEquivalent(with: event))
    #expect(editor.content.blocks[0] == code)
    #expect(editor.content.blocks.count == 2)
    #expect(editor.currentBlockKind == .paragraph)
    #expect(editor.typingAttributes[.backgroundColor] == nil)
    editor.insertText("/", replacementRange: editor.selectedRange())
    #expect(editor.hasSlashSuggestions)
    #expect(editor.content.blocks[1].kind == .paragraph)
}

@Test @MainActor func editingModeChangingCodeToParagraphPreservesLiteralSlash() {
    let editor = modeEditor(NoteContent(blocks: [NoteBlock(kind: .code, text: "/")]))
    let item = NSMenuItem()
    item.representedObject = NoteBlockKind.paragraph.rawValue
    editor.perform(NSSelectorFromString("selectKind:"), with: item)
    #expect(editor.currentBlockKind == .paragraph)
    #expect(editor.content.plainText == "/")
    #expect(editor.attributedString().attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
}
