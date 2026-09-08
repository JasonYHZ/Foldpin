import AppKit
import Testing
@testable import FoldpinCore

@MainActor private final class InsertUndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}

@MainActor private func insertionEditor(_ content: NoteContent = NoteContent()) -> PaperTextView {
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.frame = NSRect(x: 0, y: 0, width: 420, height: 420)
    editor.minSize = NSSize(width: 0, height: 420)
    editor.isRichText = true
    editor.isAutomaticDashSubstitutionEnabled = false
    editor.textContainerInset = NSSize(width: 32, height: 16)
    editor.textContainer?.lineFragmentPadding = 0
    editor.textContainer?.size = NSSize(width: 356, height: CGFloat.greatestFiniteMagnitude)
    editor.configure(content: content)
    return editor
}

@Test @MainActor func structuredInsertOrderedListsContinueRenumberExitAndUndo() throws {
    let editor = insertionEditor()
    for ch in "1. first" { editor.insertText(String(ch), replacementRange: editor.selectedRange()) }
    #expect(editor.content.blocks[0].kind == .orderedList)
    #expect(editor.content.blocks[0].text == "first")
    editor.insertNewline(nil)
    editor.insertText("second", replacementRange: editor.selectedRange())
    #expect(editor.string == "1. first\n2. second")
    editor.insertNewline(nil)
    #expect(editor.string.hasSuffix("3. "))
    editor.insertNewline(nil)
    #expect(editor.content.blocks.last?.kind == .paragraph)
    let before = editor.content
    let delegate = InsertUndoDelegate()
    delegate.history.groupsByEvent = false
    editor.delegate = delegate; editor.allowsUndo = true
    delegate.history.beginUndoGrouping()
    editor.performBlockAction(.delete, blockID: before.blocks[0].id)
    delegate.history.endUndoGrouping()
    #expect(editor.string == "1. second\n")
    delegate.history.undo()
    #expect(editor.content == before && editor.string == "1. first\n2. second\n")
    delegate.history.redo()
    #expect(editor.string == "1. second\n")
    try editor.content.validate()
}

@Test @MainActor func structuredInsertDividerKeepsFollowingContentUndoAndLiteralPastes() throws {
    for useSpace in [false, true] {
        let editor = insertionEditor(NoteContent(plainText: "---"))
        let delegate = InsertUndoDelegate()
        delegate.history.groupsByEvent = false
        editor.delegate = delegate; editor.allowsUndo = true
        let before = editor.content
        delegate.history.beginUndoGrouping()
        if useSpace { editor.insertText(" ", replacementRange: editor.selectedRange()) }
        else { editor.insertNewline(nil) }
        delegate.history.endUndoGrouping()
        #expect(editor.content.blocks.map(\.kind) == [.divider, .paragraph])
        #expect(editor.content.blocks[0].text.isEmpty)
        #expect(editor.currentBlockKind == .paragraph)
        try editor.content.validate()
        let saved = editor.content
        delegate.history.undo()
        #expect(editor.content == before)
        delegate.history.redo()
        #expect(editor.content == saved)
    }
    let editor = insertionEditor(NoteContent(plainText: "keep this"))
    editor.changeKind(.divider)
    #expect(editor.content.blocks.map(\.kind) == [.paragraph, .divider, .paragraph])
    #expect(editor.content.blocks[0].text == "keep this")
    editor.insertPastedText("---\n1. literal")
    #expect(editor.content.blocks.suffix(2).allSatisfy { $0.kind == .paragraph })
}

@Test @MainActor func structuredInsertTableEditsSaveReloadCopyAndUndo() throws {
    let editor = insertionEditor(NoteContent(plainText: "/"))
    let delegate = InsertUndoDelegate()
    delegate.history.groupsByEvent = false
    editor.delegate = delegate; editor.allowsUndo = true
    delegate.history.beginUndoGrouping()
    editor.changeKind(.table)
    delegate.history.endUndoGrouping()
    #expect(editor.content.blocks.map(\.kind) == [.table, .paragraph])
    #expect(editor.content.blocks[0].table?.rows == NoteTable().rows)
    #expect(editor.textLayoutManager != nil)
    let initial = editor.content
    let cell = try #require(editor.tableCellEditor)
    delegate.history.beginUndoGrouping()
    cell.insertText("中文 🌿\nsecond line", replacementRange: cell.selectedRange())
    delegate.history.endUndoGrouping()
    #expect(editor.content.blocks[0].table?.rows[0][0] == "中文 🌿\nsecond line")
    #expect(editor.tableCellEditor === cell)
    let edited = editor.content
    delegate.history.undo()
    #expect(editor.content == initial && cell.string.isEmpty)
    delegate.history.redo()
    #expect(editor.content == edited && cell.string == "中文 🌿\nsecond line")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NoteStore(file: NoteFile(url: directory.appendingPathComponent("note.json")))
    store.edit(editor.content)
    #expect(store.flush())
    let saved = try store.file.load()
    let reopened = insertionEditor(saved.content)
    #expect(reopened.content == edited)
    var copied: NoteContent?
    editor.writeBlockToPasteboard = { copied = $0; return true }
    editor.performBlockAction(.copy, blockID: edited.blocks[0].id)
    #expect(copied?.blocks[0].table == edited.blocks[0].table)
    #expect(copied?.plainText.contains("中文 🌿\nsecond line\t") == true)
    var invalid = saved
    invalid.content.blocks[0].table?.rows.append(["ragged"])
    #expect(throws: (any Error).self) { try store.file.save(invalid) }
    #expect(try store.file.load() == saved)
}

@Test @MainActor func structuredInsertTableTabGrowthExitAndBlockOperations() throws {
    let editor = insertionEditor()
    editor.changeKind(.table)
    let id = editor.content.blocks[0].id
    editor.beginTableCellEditing(blockID: id, row: 2, column: 1)
    editor.tableCellEditor?.insertTab(nil)
    #expect(editor.content.blocks[0].table?.rows.count == 4)
    editor.tableCellEditor?.insertText("new row", replacementRange: NSRange(location: 0, length: 0))
    #expect(editor.content.blocks[0].table?.rows[3][0] == "new row")
    editor.tableCellEditor?.insertBacktab(nil)
    #expect(editor.tableCellEditor?.string == "")
    editor.tableCellEditor?.cancelOperation(nil)
    #expect(editor.tableCellEditor == nil && editor.currentBlockKind == .paragraph)
    editor.performBlockAction(.addTableColumn, blockID: id)
    #expect(editor.content.blocks[0].table?.rows.allSatisfy { $0.count == 3 } == true)
    editor.performBlockAction(.duplicate, blockID: id)
    #expect(editor.content.blocks[0].table == editor.content.blocks[1].table)
    #expect(editor.content.blocks[0].id != editor.content.blocks[1].id)
    editor.performBlockAction(.moveDown, blockID: id)
    #expect(editor.content.blocks[1].id == id)
    editor.performBlockAction(.delete, blockID: id)
    #expect(editor.content.blocks.map(\.kind) == [.table, .paragraph])
    try editor.content.validate()
}

@Test @MainActor func structuredInsertGridGeometryAndNativePreview() throws {
    let block = NoteBlock(kind: .table, table: NoteTable(rows: [["名称", "状态"], ["有序列表", "已完成"], ["表格 🌿", "可直接编辑"]]))
    let content = NoteContent(blocks: [NoteBlock(kind: .heading, text: "原生表格"), block, NoteBlock(kind: .divider), NoteBlock(text: "继续记录…")])
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        let editor = insertionEditor(content)
        editor.appearance = NSAppearance(named: name)
        editor.textLayoutManager?.ensureLayout(for: editor.textLayoutManager!.documentRange)
        let frame = try #require(editor.tableFrame(blockID: block.id))
        #expect(frame.width > 300 && frame.height >= 102)
        editor.beginTableCellEditing(blockID: block.id, row: 1, column: 1)
        let cell = try #require(editor.tableCellEditor)
        #expect(frame.contains(cell.frame))
        #expect(editor.content == content)
        if let folder = ProcessInfo.processInfo.environment["FOLDPIN_INSERT_PREVIEW_DIR"] {
            let directory = URL(fileURLWithPath: folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bounds = editor.bounds
            let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: bounds))
            editor.cacheDisplay(in: bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("table-\(name.rawValue).png"))
        }
    }
}

@Test @MainActor func structuredInsertTableSelectionCompositionAndResizeStayNative() throws {
    let block = NoteBlock(kind: .table)
    let editor = insertionEditor(NoteContent(blocks: [block, NoteBlock()]))
    #expect(editor.selectBlock(block.id))
    editor.insertText("first", replacementRange: editor.selectedRange())
    let cell = try #require(editor.tableCellEditor)
    #expect(editor.content.blocks[0].table?.rows[0][0] == "first")
    #expect(editor.content.blocks.count == 2)
    editor.setFrameSize(NSSize(width: 500, height: 420))
    #expect(editor.tableCellEditor === cell && cell.string == "first")
    #expect(editor.textLayoutManager != nil && cell.textLayoutManager != nil)
    cell.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: cell.selectedRange())
    #expect(cell.hasMarkedText())
    #expect(!editor.performBlockAction(.delete, blockID: block.id))
    cell.unmarkText()
    #expect(editor.content.blocks[0].table?.rows[0][0] == cell.string)
    #expect(editor.selectBlock(block.id))
    #expect(editor.tableCellEditor == nil)
    try editor.content.validate()
}
