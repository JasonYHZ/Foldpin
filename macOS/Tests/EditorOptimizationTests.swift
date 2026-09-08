import AppKit
import Testing
@testable import FoldpinCore

@MainActor private func optimizedEditor(_ content: NoteContent) -> PaperTextView {
    let view = PaperTextView(usingTextLayoutManager: true)
    view.frame = NSRect(x: 0, y: 0, width: 440, height: 500)
    view.textContainerInset = NSSize(width: 32, height: 16)
    view.textContainer?.lineFragmentPadding = 0
    view.textContainer?.size = NSSize(width: 376, height: 100_000)
    view.textContainer?.widthTracksTextView = true
    view.isRichText = true
    view.configure(content: content)
    return view
}

@Test @MainActor func optimizedGeometryFollowsEditsWrappingAndAttributes() throws {
    let block = NoteBlock(kind: .code, text: String(repeating: "let value = 42; ", count: 24), language: .swift)
    let view = optimizedEditor(NoteContent(blocks: [block, NoteBlock(text: "end")]))
    let first = try #require(view.codeBlockSurfaces().first).rect
    #expect(view.codeBlockSurfaces().first?.rect == first)
    view.setFrameSize(NSSize(width: 240, height: 500))
    let narrow = try #require(view.codeBlockSurfaces().first).rect
    #expect(narrow.width < first.width && narrow.height > first.height)
    view.setSelectedRange(NSRange(location: 0, length: 0))
    view.insertText("\n\n", replacementRange: view.selectedRange())
    let edited = try #require(view.codeBlockSurfaces().first).rect
    #expect(edited.height > narrow.height)
    view.textStorage?.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 25, weight: .regular),
                                  range: NSRange(location: 0, length: 20))
    #expect(try #require(view.codeBlockSurfaces().first).rect.height > edited.height)
    #expect(view.content.blocks[0].text == "\n\n" + block.text)
}

@Test @MainActor func optimizedTableEditPreservesUnrelatedNativeAttributesAndCell() async throws {
    let code = NoteBlock(kind: .code, text: "let value = 42", language: .swift)
    _ = await CodeSyntaxEngine.shared.analyze(code.text, language: code.language)
    let table = NoteBlock(kind: .table)
    let view = optimizedEditor(NoteContent(blocks: [code, table, NoteBlock(text: "正文 🌿")]))
    view.beginTableCellEditing(blockID: table.id, row: 0, column: 0)
    let cell = try #require(view.tableCellEditor)
    let storage = try #require(view.textStorage)
    let marker = NSAttributedString.Key("test.native.annotation")
    // An unrelated native annotation must survive editing an attachment.
    storage.addAttribute(marker, value: "keep", range: NSRange(location: 0, length: code.text.utf16.count))
    let oldCode = storage.attributedSubstring(from: NSRange(location: 0, length: code.text.utf16.count))
    var published: NoteContent?
    view.onContentChange = { published = $0 }
    cell.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: cell.selectedRange())
    #expect(cell.hasMarkedText() && view.tableCellEditor === cell)
    #expect(storage.attributedSubstring(from: NSRange(location: 0, length: code.text.utf16.count)) == oldCode)
    #expect(published?.blocks[1].table?.rows[0][0] == "中文")
    cell.unmarkText()
    #expect(NoteContent(blocks: BlockTextCodec.read(view.attributedString(), typing: view.typingAttributes).map(\.block)) == view.content)
    #expect(view.content.blocks[2].text == "正文 🌿")
}

@Test @MainActor func optimizedTableLayoutMatchesFreshLayoutAfterCellAndWidthChanges() {
    var table = NoteTable(rows: [["A", "B"], ["short", "value"], ["last", "cell"]])
    let before = TableBlockLayout(table: table, width: 360)
    table.rows[1][0] = String(repeating: "长内容 🌿 ", count: 20)
    for width in [360.0, 200.0] {
        let reused = TableBlockLayout(table: table, width: width, reusing: before)
        let fresh = TableBlockLayout(table: table, width: width)
        #expect(reused.size == fresh.size)
        for row in table.rows.indices {
            for column in table.rows[row].indices {
                let rect = reused.rect(row: row, column: column)
                #expect(rect == fresh.rect(row: row, column: column))
                let hit = reused.cell(at: NSPoint(x: rect.midX, y: rect.midY))
                #expect(hit?.row == row && hit?.column == column)
            }
        }
    }
}
