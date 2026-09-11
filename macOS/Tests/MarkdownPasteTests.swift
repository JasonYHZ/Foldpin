import AppKit
import Testing
@testable import FoldpinCore

@MainActor private final class PasteUndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}

@MainActor private func pasteEditor(_ content: NoteContent = NoteContent()) -> PaperTextView {
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.frame = NSRect(x: 0, y: 0, width: 500, height: 500)
    editor.textContainer?.size = NSSize(width: 450, height: CGFloat.greatestFiniteMagnitude)
    editor.isRichText = true
    editor.configure(content: content)
    return editor
}

@Test @MainActor func markdownPasteParsesSupportedBlocksAndKeepsCodeLiteral() throws {
    let source = """
    # 标题一
    ## 标题二
    ### 标题三
    #### 标题四

    正文 **加粗** *斜体*。

    - 项目
    - [ ] 待办
    - [x] 完成

    1. 第一项
    2. 第二项

    > 引用
    > 第二行

    ---

    ```java
    // **not bold**
    class Demo {}
    ```

    | 名称 | 状态 |
    | --- | --- |
    | 🌿 | 完成 |
    """
    let content = try #require(MarkdownPasteParser.parse(source))
    #expect(content.blocks.map(\.kind) == [.heading, .subheading, .heading3, .heading4, .paragraph,
        .bullet, .task, .task, .orderedList, .orderedList, .quote, .divider, .code, .table])
    #expect(content.blocks[6].text == "待办" && !content.blocks[6].isChecked)
    #expect(content.blocks[7].text == "完成" && content.blocks[7].isChecked)
    #expect(content.blocks[10].text == "引用\u{2028}第二行")
    #expect(content.blocks[12].text == "// **not bold**\nclass Demo {}\n")
    #expect(content.blocks[12].language == .java && content.blocks[12].marks.isEmpty)
    #expect(content.blocks[13].table?.rows == [["名称", "状态"], ["🌿", "完成"]])
    try content.validate()
}

@Test @MainActor func markdownPasteHandlesUnicodeInlineStylesAndOldMarkFiles() throws {
    let parsed = try #require(MarkdownPasteParser.parse("中文🌿 **粗体**、*斜体*、`a_b`、~~删除~~、[官网](https://example.com)"))
    let block = try #require(parsed.blocks.first)
    #expect(block.text == "中文🌿 粗体、斜体、a_b、删除、官网")
    let ns = block.text as NSString
    for (label, predicate) in [
        ("粗体", { (mark: NoteTextMark) in mark.bold }),
        ("斜体", { (mark: NoteTextMark) in mark.italic }),
        ("a_b", { (mark: NoteTextMark) in mark.code }),
        ("删除", { (mark: NoteTextMark) in mark.strikethrough }),
        ("官网", { (mark: NoteTextMark) in mark.link == "https://example.com" })
    ] {
        let mark = try #require(block.marks.first(where: predicate))
        #expect(ns.substring(with: NSRange(location: mark.location, length: mark.length)) == label)
    }
    let legacy = Data(#"{"location":0,"length":2,"bold":true,"italic":false}"#.utf8)
    let mark = try JSONDecoder().decode(NoteTextMark.self, from: legacy)
    #expect(mark.bold && !mark.code && !mark.strikethrough && mark.link == nil)
    let restored = try JSONDecoder().decode(NoteContent.self, from: JSONEncoder().encode(parsed))
    #expect(restored == parsed)
    let editor = pasteEditor(parsed)
    #expect(editor.content == parsed)
    let codeRange = ns.range(of: "a_b")
    #expect(editor.attributedString().attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil) != nil)
    #expect(editor.attributedString().attribute(.link, at: ns.range(of: "官网").location, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
    #expect(editor.textLayoutManager != nil)
}

@Test @MainActor func markdownPasteFallbacksPreserveUnsupportedContentAndOrdinaryText() throws {
    for text in ["普通文字\n第二行\n\n", "https://example.com/a_b", "a_b_c", "1 + 2", "#hashtag", "\\# literal", "**unclosed", "text /"] {
        #expect(MarkdownPasteParser.parse(text) == nil)
        let editor = pasteEditor()
        editor.insertPastedText(text)
        #expect(editor.string == text)
        #expect(!editor.hasSlashSuggestions)
    }
    for literal in ["![图片](https://example.com/a.png)", "<script>alert(1)</script>", "##### H5", "[run](javascript:alert)"] {
        let parsed = try #require(MarkdownPasteParser.parse("# 标题\n\n" + literal, importingRemoteImages: false))
        #expect(parsed.blocks.first?.kind == .heading)
        #expect(parsed.blocks.last?.text == literal)
        #expect(parsed.blocks.last?.marks.isEmpty == true)
    }
    let nested = try #require(MarkdownPasteParser.parse("- parent\n  - child"))
    #expect(nested.blocks[0].kind == .bullet && nested.blocks[1].text == "  - child")
}

@Test @MainActor func markdownPasteEmptyBlocksTablesCRLFAndFenceLanguages() throws {
    let empty = try #require(MarkdownPasteParser.parse("#\n\n```swift\n```\n\n---"))
    #expect(empty.blocks.map(\.kind) == [.heading, .code, .divider])
    #expect(empty.blocks[1].text.isEmpty && empty.blocks[1].language == .swift)
    let table = try #require(MarkdownPasteParser.parse("| | |\r\n|---|---|\r\n| | |\r\n| a | b |\r\n| | |"))
    #expect(table.blocks[0].table?.rows == [["", ""], ["", ""], ["a", "b"], ["", ""]])
    let setext = try #require(MarkdownPasteParser.parse("Heading\n=======\n\nbody **bold**"))
    #expect(setext.blocks.map(\.kind) == [.heading, .paragraph])
    for (hint, language) in [("js", CodeLanguage.javascript), ("python", .python), ("text", .plain), ("unknown", .automatic)] {
        let content = try #require(MarkdownPasteParser.parse("~~~\(hint)\r\nx\r\n~~~"))
        #expect(content.blocks[0].kind == .code && content.blocks[0].language == language)
        #expect(content.blocks[0].text == "x\n")
    }
}

@Test @MainActor func markdownPasteAtSelectionKeepsBothEdgesCaretUndoAndSavedData() throws {
    let original = NoteContent(blocks: [NoteBlock(text: "前文🌿后文", marks: [NoteTextMark(location: 0, length: 2, bold: true)])])
    let editor = pasteEditor(original)
    let delegate = PasteUndoDelegate()
    delegate.history.groupsByEvent = false
    editor.delegate = delegate; editor.allowsUndo = true
    editor.setSelectedRange(NSRange(location: 2, length: 2))
    delegate.history.beginUndoGrouping()
    editor.insertPastedText("# 标题\n\n正文 **重要**")
    delegate.history.endUndoGrouping()
    #expect(editor.content.blocks.map(\.kind) == [.paragraph, .heading, .paragraph])
    #expect(editor.content.blocks[0].text == "前文" && editor.content.blocks[0].marks == original.blocks[0].marks)
    #expect(editor.content.blocks[1].text == "标题")
    #expect(editor.content.blocks[2].text == "正文 重要后文")
    let pasted = editor.content
    delegate.history.undo()
    #expect(editor.content == original)
    delegate.history.redo()
    #expect(editor.content == pasted)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = NoteFile(url: directory.appendingPathComponent("note.json"))
    var document = NoteDocument(); document.content = pasted
    try file.save(document)
    #expect(try file.load().content == pasted)
    let current = pasteEditor(original)
    current.setSelectedRange(NSRange(location: 2, length: 2))
    current.insertPastedText("# 标题\n\n正文 **重要**")
    current.insertText("!", replacementRange: current.selectedRange())
    #expect(current.content.blocks[2].text == "正文 重要!后文")
}

@Test @MainActor func markdownPasteInlineMergesAndDoesNotLeakLinkOrCodeStyle() throws {
    let original = NoteBlock(kind: .heading, text: "ABCD")
    let editor = pasteEditor(NoteContent(blocks: [original]))
    editor.setSelectedRange(NSRange(location: 1, length: 2))
    editor.insertPastedText("**🌿**")
    #expect(editor.content.blocks.count == 1 && editor.currentBlockKind == .heading)
    #expect(editor.content.blocks[0].id == original.id && editor.content.blocks[0].text == "A🌿D")
    #expect(editor.content.blocks[0].marks == [NoteTextMark(location: 1, length: 2, bold: true)])
    let rich = try #require(MarkdownPasteParser.parse("`code` [link](https://example.com)"))
    editor.configure(content: rich)
    editor.setSelectedRange(NSRange(location: 2, length: 0))
    editor.insertPastedText("# heading")
    #expect(editor.content.blocks.map(\.kind) == [.paragraph, .heading, .paragraph])
    let ns = editor.string as NSString
    #expect(editor.attributedString().attribute(.link, at: ns.range(of: "heading").location, effectiveRange: nil) == nil)
    #expect(editor.attributedString().attribute(.backgroundColor, at: ns.range(of: "heading").location, effectiveRange: nil) == nil)
    #expect(editor.content.blocks[0].marks.first?.code == true)
    #expect(editor.content.blocks[2].marks.contains(where: { $0.link != nil }) == true)
}

@Test @MainActor func markdownPasteAcrossBlocksAndAttachmentInsertionRemainEditable() throws {
    let original = NoteContent(blocks: [NoteBlock(text: "prefixABC"), NoteBlock(kind: .heading, text: "DEsuffix"), NoteBlock(kind: .divider)])
    let editor = pasteEditor(original)
    editor.setSelectedRange(NSRange(location: 6, length: 6))
    editor.insertPastedText("- one\n- two")
    #expect(editor.content.blocks.map(\.kind) == [.paragraph, .bullet, .bullet, .heading, .divider])
    #expect(editor.content.blocks[0].text == "prefix" && editor.content.blocks[3].text == "suffix")
    let table = pasteEditor()
    table.insertPastedText("| A | B |\n|---|---|\n| 1 | 2 |")
    #expect(table.content.blocks.map(\.kind) == [.table, .paragraph])
    table.insertText("after", replacementRange: table.selectedRange())
    #expect(table.content.blocks[1].text == "after")
    table.beginTableCellEditing(blockID: table.content.blocks[0].id, row: 0, column: 0)
    table.insertPastedText("**literal**")
    #expect(table.content.blocks[0].table?.rows[0][0].contains("**literal**") == true)
    let structured = pasteEditor(NoteContent(plainText: "replace"))
    structured.selectAll(nil)
    #expect(structured.insertPastedBlocks(table.content))
    #expect(structured.content.blocks.map(\.kind) == [.table, .paragraph])
    #expect(structured.content.blocks[0].id != table.content.blocks[0].id)
    try structured.content.validate()
}

@Test @MainActor func markdownPastePlainTextCodeReadOnlyAndIMEUseLiteralPath() {
    let source = "# heading\n\n**literal** /"
    let plain = pasteEditor()
    plain.insertPastedText(source, interpretingMarkdown: false)
    #expect(plain.string == source && plain.content.blocks.allSatisfy { $0.kind == .paragraph })
    #expect(!plain.hasSlashSuggestions)
    let code = pasteEditor(NoteContent(blocks: [NoteBlock(kind: .code)]))
    code.insertPastedText(source)
    #expect(code.content.blocks.count == 1 && code.content.blocks[0].text == source)
    #expect(code.content.blocks[0].kind == .code)
    let readonly = pasteEditor()
    readonly.isEditable = false
    readonly.insertPastedText(source)
    #expect(readonly.string.isEmpty)
    let ime = pasteEditor()
    ime.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: ime.selectedRange())
    ime.insertPastedText(source)
    #expect(ime.content.blocks.allSatisfy { $0.kind == .paragraph })
}
