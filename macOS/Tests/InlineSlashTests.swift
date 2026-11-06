import AppKit
import Testing
@testable import FoldpinCore

@MainActor private final class InlineSlashUndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}

@MainActor private func inlineSlashEditor(_ content: NoteContent = NoteContent()) -> PaperTextView {
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.frame = NSRect(x: 0, y: 0, width: 420, height: 420)
    editor.isRichText = true
    editor.configure(content: content)
    return editor
}

@Test @MainActor func inlineSlashTypingBackspaceEscapeAndRepeatedCommands() {
    let editor = inlineSlashEditor(NoteContent(plainText: "已经写好的正文"))
    var shelved = false
    editor.onEscape = { shelved = true }
    editor.insertText(" ", replacementRange: editor.selectedRange())
    editor.insertText("/", replacementRange: editor.selectedRange())
    #expect(editor.hasSlashSuggestions)
    editor.deleteBackward(nil)
    #expect(!editor.hasSlashSuggestions && editor.content.plainText == "已经写好的正文 ")
    editor.insertText("/", replacementRange: editor.selectedRange())
    editor.cancelOperation(nil)
    #expect(!editor.hasSlashSuggestions && !shelved)
    #expect(editor.content.plainText == "已经写好的正文 /")
    editor.insertText("　", replacementRange: editor.selectedRange())
    editor.insertText("/", replacementRange: editor.selectedRange())
    #expect(editor.hasSlashSuggestions)
    editor.insertText("继续输入", replacementRange: editor.selectedRange())
    #expect(!editor.hasSlashSuggestions)
    #expect(editor.content.plainText == "已经写好的正文 /　/继续输入")
}

@Test @MainActor func inlineSlashLiteralInputAndCompositionDoNotOpenSuggestions() {
    for prefix in ["https:", "https:/", "foo", "foo/", "\t", "line\u{2028}"] {
        let editor = inlineSlashEditor(NoteContent(blocks: [NoteBlock(text: prefix)]))
        editor.insertText("/", replacementRange: editor.selectedRange())
        #expect(!editor.hasSlashSuggestions)
        #expect(editor.content.plainText == prefix + "/")
    }
    let code = inlineSlashEditor(NoteContent(blocks: [NoteBlock(kind: .code, text: "let x = ")]))
    code.insertText("/", replacementRange: code.selectedRange())
    #expect(!code.hasSlashSuggestions)
    let pasted = inlineSlashEditor(NoteContent(plainText: "text "))
    pasted.insertPastedText("/")
    #expect(!pasted.hasSlashSuggestions && pasted.content.plainText == "text /")
    let loaded = inlineSlashEditor(NoteContent(plainText: "saved /"))
    #expect(!loaded.hasSlashSuggestions)
    loaded.setSelectedRange(NSRange(location: 6, length: 1))
    loaded.insertText("/", replacementRange: loaded.selectedRange())
    #expect(!loaded.hasSlashSuggestions)
    let composing = inlineSlashEditor(NoteContent(plainText: "中文 "))
    composing.setMarkedText("/", selectedRange: NSRange(location: 1, length: 0), replacementRange: composing.selectedRange())
    #expect(composing.hasMarkedText() && !composing.hasSlashSuggestions)
    composing.insertText("/", replacementRange: composing.markedRange())
    #expect(!composing.hasSlashSuggestions)
}

@Test @MainActor func inlineSlashKeyboardInsertionPreservesPrefixAndSupportsUndoAndSave() throws {
    let original = NoteBlock(text: "保留 🌿 ", marks: [NoteTextMark(location: 0, length: 2, bold: true)])
    let editor = inlineSlashEditor(NoteContent(blocks: [original]))
    editor.insertText("/", replacementRange: editor.selectedRange())
    let before = editor.content
    let delegate = InlineSlashUndoDelegate()
    delegate.history.groupsByEvent = false
    editor.delegate = delegate; editor.allowsUndo = true
    delegate.history.beginUndoGrouping()
    editor.moveDown(nil)
    editor.insertNewline(nil)
    delegate.history.endUndoGrouping()
    #expect(editor.content.blocks.map(\.kind) == [.paragraph, .heading])
    #expect(editor.content.blocks[0] == original)
    #expect(editor.content.blocks[1].text.isEmpty && editor.currentBlockKind == .heading)
    #expect(!editor.hasSlashSuggestions)
    let after = editor.content
    delegate.history.undo()
    #expect(editor.content == before && !editor.hasSlashSuggestions)
    delegate.history.redo()
    #expect(editor.content == after)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = NoteFile(url: directory.appendingPathComponent("note.json"))
    var document = NoteDocument()
    document.content = after
    try file.save(document)
    #expect(try file.load().content == after)
}

@Test @MainActor func inlineSlashSplitsTextAtCaretKeepingSuffixAndMarks() throws {
    let prefix = "之前 🌿 "
    let suffix = "之后 中文"
    let text = prefix + suffix
    for kind in NoteBlockKind.allCases where !kind.isAttachment {
        let source = NoteBlock(kind: .task, text: text,
            marks: [NoteTextMark(location: 0, length: (text as NSString).length, bold: true)], isChecked: true)
        let editor = inlineSlashEditor(NoteContent(blocks: [source, NoteBlock(text: "后续块")]))
        // Account for the native task marker, which is display data only.
        editor.setSelectedRange(NSRange(location: 2 + (prefix as NSString).length, length: 0))
        editor.insertText("/", replacementRange: editor.selectedRange())
        #expect(editor.hasSlashSuggestions)
        editor.changeKind(kind)
        #expect(editor.content.blocks.map(\.kind) == [.task, kind, .paragraph])
        #expect(editor.content.blocks[0].id == source.id && editor.content.blocks[0].isChecked)
        #expect(editor.content.blocks[0].text == prefix)
        #expect(editor.content.blocks[0].marks == [NoteTextMark(location: 0, length: (prefix as NSString).length, bold: true)])
        #expect(editor.content.blocks[1].text == suffix && !editor.content.blocks[1].isChecked)
        #expect(editor.content.blocks[1].marks == (kind == .code ? [] : [NoteTextMark(location: 0, length: (suffix as NSString).length, bold: true)]))
        #expect(editor.content.blocks[2].text == "后续块")
        #expect(editor.currentBlockKind == kind)
        if kind == .code { #expect(editor.content.blocks[1].language == .automatic) }
        try editor.content.validate()
    }
}

@Test @MainActor func inlineSlashDividerAndTableKeepTextOnBothSides() throws {
    for kind in [NoteBlockKind.divider, .table] {
        let editor = inlineSlashEditor(NoteContent(plainText: "前文 后文"))
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.insertText("/", replacementRange: editor.selectedRange())
        editor.changeKind(kind)
        #expect(editor.content.blocks.map(\.kind) == [.paragraph, kind, .paragraph])
        #expect(editor.content.blocks[0].text == "前文 ")
        #expect(editor.content.blocks[2].text == "后文")
        if kind == .table {
            #expect(editor.tableCellEditor != nil)
            #expect(editor.content.blocks[1].table == NoteTable())
        } else { #expect(editor.currentBlockKind == .paragraph) }
        try editor.content.validate()
    }
}

@Test @MainActor func inlineSlashDelayedImageInsertionRejectsChangedSource() throws {
    let source = NoteBlock(text: "前文 /后文", marks: [NoteTextMark(location: 4, length: 2, italic: true)])
    let context = try #require(SlashCommandContext(block: source, caretOffset: 4))
    let image = NoteBlock(kind: .image, image: NoteImage(id: UUID(), name: "sample.png", pixelWidth: 10, pixelHeight: 10))
    let original = NoteContent(blocks: [source])
    let inserted = try #require(context.inserting(image, in: original))
    #expect(inserted.content.blocks.map(\.kind) == [.paragraph, .image, .paragraph])
    #expect(inserted.content.blocks[0].text == "前文 " && inserted.content.blocks[2].text == "后文")
    #expect(inserted.content.blocks[1].image == image.image && inserted.focusIndex == 2)
    #expect(inserted.content.blocks[2].marks == [NoteTextMark(location: 0, length: 2, italic: true)])
    try inserted.content.validate()
    var changed = original
    changed.blocks[0].text += "changed"
    #expect(context.inserting(image, in: changed) == nil)
    #expect(context.inserting(image, in: NoteContent()) == nil)
    #expect(original.blocks[0] == source)
}

@Test @MainActor func inlineSlashStartOfBlockAndEndMediaRetainCaretDestination() throws {
    for kind in [NoteBlockKind.heading, .divider, .table] {
        let editor = inlineSlashEditor()
        let id = editor.content.blocks[0].id
        editor.insertText("/", replacementRange: editor.selectedRange())
        editor.changeKind(kind)
        #expect(editor.content.blocks[0].id == id && editor.content.blocks[0].kind == kind)
        #expect(editor.content.blocks.count == (kind == .heading ? 1 : 2))
        try editor.content.validate()
    }
    let editor = inlineSlashEditor(NoteContent(plainText: "末尾 "))
    editor.insertText("/", replacementRange: editor.selectedRange())
    editor.changeKind(.divider)
    #expect(editor.content.blocks.map(\.kind) == [.paragraph, .divider, .paragraph])
    editor.insertText("继续写", replacementRange: editor.selectedRange())
    #expect(editor.content.blocks[2].text == "继续写")
}

@Test @MainActor func inlineSlashRepeatedArrowsChooseTheSameItemAsEmptyBlockMenu() {
    for prefix in ["", "已有文字 ", "中文 🌿　"] {
        let editor = inlineSlashEditor(NoteContent(plainText: prefix))
        editor.insertText("/", replacementRange: editor.selectedRange())
        let kinds = NoteBlockKind.allCases.filter { $0 != .file && $0 != .linkPreview }
        let codeIndex = kinds.firstIndex(of: .code)!
        for _ in 0..<(kinds.count + 1 + codeIndex) { editor.moveDown(nil) }
        #expect(editor.hasSlashSuggestions)
        editor.insertNewline(nil)
        #expect(!editor.hasSlashSuggestions && editor.currentBlockKind == .code)
        #expect(editor.content.blocks.last?.text.isEmpty == true)
        if !prefix.isEmpty { #expect(editor.content.blocks[0].text == prefix) }
    }
}
