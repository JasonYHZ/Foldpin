import AppKit
import Testing
@testable import FoldpinCore

@MainActor private func makeMarkdownEditor(_ content: NoteContent = NoteContent()) -> PaperTextView {
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.isRichText = true
    editor.configure(content: content)
    return editor
}

@MainActor private func typeMarkdown(_ text: String, in editor: PaperTextView) {
    for character in text { editor.insertText(String(character), replacementRange: editor.selectedRange()) }
}

@Test @MainActor func markdownBlockPrefixesBecomeStructuredBlocksWhenSpaceIsTyped() {
    let cases: [(String, NoteBlockKind, Bool)] = [
        ("#", .heading, false), ("##", .subheading, false),
        ("-", .bullet, false), ("*", .bullet, false), ("+", .bullet, false),
        (">", .quote, false), ("[]", .task, false), ("[ ]", .task, false),
        ("[x]", .task, true), ("[X]", .task, true),
        ("- [ ]", .task, false), ("- [x]", .task, true)
    ]
    for (prefix, kind, checked) in cases {
        let editor = makeMarkdownEditor()
        let originalID = editor.content.blocks[0].id
        typeMarkdown(prefix + " ", in: editor)
        #expect(editor.content.blocks.count == 1)
        #expect(editor.content.blocks[0].id == originalID)
        #expect(editor.content.blocks[0].kind == kind)
        #expect(editor.content.blocks[0].isChecked == checked)
        #expect(editor.content.blocks[0].text.isEmpty)
        typeMarkdown("内容", in: editor)
        #expect(editor.content.blocks[0].text == "内容")
        #expect(editor.content.blocks[0].kind == kind)
    }
}

@Test @MainActor func markdownHeadingKeepsFollowingTextMarksAndSavesAsJSON() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NoteStore(file: NoteFile(url: directory.appendingPathComponent("note.json")))
    let block = NoteBlock(text: "#重点 🌿", marks: [NoteTextMark(location: 1, length: 2, bold: true)])
    let editor = makeMarkdownEditor(NoteContent(blocks: [block]))
    editor.onContentChange = { store.edit($0) }
    editor.setSelectedRange(NSRange(location: 1, length: 0))
    typeMarkdown(" ", in: editor)
    #expect(editor.content.blocks[0].text == "重点 🌿")
    #expect(editor.content.blocks[0].marks == [NoteTextMark(location: 0, length: 2, bold: true)])
    #expect(editor.selectedRange().location == 0)
    #expect(store.flush())
    let restored = try store.file.load()
    #expect(restored.version == 2)
    #expect(restored.content.blocks[0].id == block.id)
    #expect(restored.content.blocks[0].kind == .heading)
    #expect(restored.text == "重点 🌿")
}

@Test @MainActor func markdownCodeFenceSelectsLanguageOnReturnAndCodeStaysLiteral() {
    for (fence, language) in [("```", CodeLanguage.plain), ("```swift", .swift), ("```js", .javascript), ("```py", .python)] {
        let editor = makeMarkdownEditor()
        typeMarkdown(fence, in: editor)
        #expect(editor.content.blocks[0].kind == .paragraph)
        editor.insertNewline(nil)
        #expect(editor.content.blocks.count == 1)
        #expect(editor.content.blocks[0].kind == .code)
        #expect(editor.content.blocks[0].language == language)
        typeMarkdown("# ", in: editor)
        #expect(editor.content.blocks[0].text == "# ")
        #expect(editor.content.blocks[0].kind == .code)
    }
    let editor = makeMarkdownEditor()
    typeMarkdown("```sql ", in: editor)
    #expect(editor.content.blocks[0].kind == .code)
    #expect(editor.content.blocks[0].language == .sql)
}

@MainActor private final class MarkdownUndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}

@Test @MainActor func markdownConversionAndTypingUndoWithoutLosingOriginalCharacters() {
    for (prefix, kind, language) in [("#", NoteBlockKind.heading, CodeLanguage.plain), ("```swift", .code, .swift)] {
        let editor = makeMarkdownEditor()
        let originalID = editor.content.blocks[0].id
        let delegate = MarkdownUndoDelegate()
        delegate.history.groupsByEvent = false
        editor.delegate = delegate; editor.allowsUndo = true
        delegate.history.beginUndoGrouping()
        typeMarkdown(prefix, in: editor)
        delegate.history.endUndoGrouping()
        delegate.history.beginUndoGrouping()
        if kind == .code { editor.insertNewline(nil) }
        else { typeMarkdown(" ", in: editor) }
        delegate.history.endUndoGrouping()
        #expect(editor.content.blocks[0].kind == kind)
        delegate.history.undo()
        #expect(editor.content.blocks[0].kind == .paragraph)
        #expect(editor.content.plainText == prefix)
        delegate.history.redo()
        #expect(editor.content.blocks[0].kind == kind)
        #expect(editor.content.blocks[0].id == originalID)
        #expect(editor.content.blocks[0].language == language)
        #expect(editor.content.plainText.isEmpty)
        delegate.history.beginUndoGrouping()
        typeMarkdown("内容", in: editor)
        delegate.history.endUndoGrouping()
        #expect(editor.content.blocks[0].kind == kind)
        delegate.history.undo()
        #expect(editor.content.plainText.isEmpty)
        #expect(editor.content.blocks[0].kind == kind)
        delegate.history.undo()
        delegate.history.undo()
        #expect(editor.content.plainText.isEmpty)
        #expect(editor.content.blocks[0].kind == .paragraph)
    }
}

@Test @MainActor func markdownDoesNotConvertRestoredPastedEscapedOrMidSentenceText() {
    let restored = makeMarkdownEditor(NoteContent(plainText: "# preserved\n- literal"))
    #expect(restored.content.blocks.allSatisfy { $0.kind == .paragraph })
    let batch = makeMarkdownEditor()
    batch.insertText("# pasted text", replacementRange: batch.selectedRange())
    #expect(batch.content.blocks[0].kind == .paragraph)
    for text in ["C# ", "\\# ", "### ", "text > ", "    # "] {
        let editor = makeMarkdownEditor()
        typeMarkdown(text, in: editor)
        #expect(editor.content.blocks[0].kind == .paragraph)
        #expect(editor.content.plainText == text)
    }
    // Exercise the external-text paste insertion path without accessing the
    // user's clipboard or requiring a pasteboard service in the test sandbox.
    let editor = makeMarkdownEditor()
    typeMarkdown("#", in: editor)
    editor.insertPastedText(" ")
    #expect(editor.content.blocks[0].kind == .paragraph)
    #expect(editor.content.plainText == "# ")
}

@Test @MainActor func markdownDoesNotTransformASelectionReplacementOrIMEComposition() {
    let editor = makeMarkdownEditor(NoteContent(plainText: "#x"))
    editor.setSelectedRange(NSRange(location: 1, length: 1))
    editor.insertText(" ", replacementRange: editor.selectedRange())
    #expect(editor.content.blocks[0].kind == .paragraph)
    #expect(editor.content.plainText == "# ")

    editor.configure(content: NoteContent(plainText: "#"))
    editor.setMarkedText(" ", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
    #expect(editor.hasMarkedText())
    editor.insertText(" ", replacementRange: editor.markedRange())
    #expect(editor.content.blocks[0].kind == .paragraph)
    #expect(editor.content.plainText == "# ")
}
