import AppKit
import Testing
@testable import FoldpinCore

@MainActor private final class ContextHistory: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}

@MainActor private func contextEditor(_ content: NoteContent) -> PaperTextView {
    _ = NSApplication.shared
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.frame = NSRect(x: 0, y: 0, width: 480, height: 900)
    editor.textContainerInset = NSSize(width: 32, height: 16)
    editor.textContainer?.size = NSSize(width: 416, height: 100_000)
    editor.textContainer?.widthTracksTextView = true
    editor.textContainer?.lineFragmentPadding = 0
    editor.isRichText = true
    editor.configure(content: content)
    return editor
}

@Test func contextColorSubmenuFitsOnEitherSideAndSmallScreens() {
    let screen = CGRect(x: -1440, y: 120, width: 1440, height: 900)
    let parent = CGRect(x: -900, y: 250, width: 340, height: 380)
    let row = CGRect(x: -893, y: 400, width: 326, height: 37)
    let right = NoteActionsLayout.submenuFrame(parent: parent, row: row, screen: screen)
    #expect(right.minX == parent.maxX + 4 && right.maxY == row.maxY + 6)
    let edge = CGRect(x: -360, y: 250, width: 340, height: 380)
    let left = NoteActionsLayout.submenuFrame(parent: edge, row: row, screen: screen)
    #expect(left.maxX == edge.minX - 4 && screen.insetBy(dx: 8, dy: 8).contains(left))
    let tiny = CGRect(x: 0, y: 0, width: 260, height: 170)
    let fitted = NoteActionsLayout.submenuFrame(parent: parent, row: row, screen: tiny)
    #expect(tiny.insetBy(dx: 8, dy: 8).contains(fitted))
}

@Test @MainActor func contextFormattingPreservesSelectionStructureAndUndo() throws {
    let original = NoteContent(blocks: [NoteBlock(kind: .heading, text: "Hello 中文"), NoteBlock(text: "neighbor")])
    let editor = contextEditor(original)
    let delegate = ContextHistory(); delegate.history.groupsByEvent = false
    editor.delegate = delegate; editor.allowsUndo = true
    let selection = NSRange(location: 0, length: 5)
    editor.setSelectedRange(selection)
    for name in ["toggleBold:", "toggleItalic:", "toggleStrikethrough:", "toggleInlineCode:"] {
        let menu = try #require(editor.makeTextActionMenu(blockID: original.blocks[0].id))
        let item = try #require(menu.items.first { $0.action == NSSelectorFromString(name) })
        delegate.history.beginUndoGrouping()
        #expect(NSApplication.shared.sendAction(NSSelectorFromString(name), to: item.target, from: item))
        delegate.history.endUndoGrouping()
        #expect(editor.selectedRange() == selection)
        #expect(editor.content.blocks[0].kind == .heading && editor.content.blocks[1] == original.blocks[1])
    }
    let styled = editor.content
    let mark = try #require(styled.blocks[0].marks.first)
    #expect(mark.bold && mark.italic && mark.code && mark.strikethrough && mark.length == 5)
    let menu = try #require(editor.makeTextActionMenu(blockID: original.blocks[0].id))
    let clear = try #require(menu.items.first { $0.action == NSSelectorFromString("clearInlineFormatting:") })
    delegate.history.beginUndoGrouping()
    #expect(NSApplication.shared.sendAction(NSSelectorFromString("clearInlineFormatting:"), to: clear.target, from: clear))
    delegate.history.endUndoGrouping()
    #expect(editor.content == original && editor.selectedRange() == selection)
    delegate.history.undo()
    #expect(editor.content == styled)
    delegate.history.redo()
    #expect(editor.content == original)
    editor.configure(content: NoteContent(blocks: [NoteBlock(kind: .code, text: "var x = 1", language: .plain)]))
    editor.setSelectedRange(NSRange(location: 0, length: 3))
    let codeMenu = try #require(editor.makeTextActionMenu(blockID: editor.content.blocks[0].id))
    #expect(!codeMenu.items.contains { $0.action == NSSelectorFromString("toggleBold:") })
}

@Test @MainActor func contextMenusResolvePointerAndBindCodeAndTableTargets() throws {
    let table = NoteBlock(kind: .table, table: NoteTable(rows: [["A", "B"], ["C", "D"]]))
    let code = NoteBlock(kind: .code, text: "let x = 1", language: .plain)
    let divider = NoteBlock(kind: .divider)
    let editor = contextEditor(NoteContent(blocks: [NoteBlock(text: "neighbor"), divider, table, code]))
    #expect(editor.selectBlock(code.id))
    let surface = try #require(editor.blockSurfaces().first { $0.blockID == divider.id })
    let menu = try #require(editor.contextMenu(at: NSPoint(x: surface.rect.midX, y: surface.rect.midY)))
    #expect(editor.selectedBlockID == divider.id)
    #expect(menu.items.compactMap { $0.representedObject as? BlockMenuCommand }.allSatisfy { $0.blockID == divider.id })
    editor.beginTableCellEditing(blockID: table.id, row: 1, column: 1)
    let cell = try #require(editor.tableCellEditor)
    let cellMenu = try #require(cell.onContextMenu?())
    #expect(cellMenu.items.contains { ($0.representedObject as? BlockMenuCommand)?.action == .deleteTableRow(1) })
    #expect(cellMenu.items.contains { ($0.representedObject as? BlockMenuCommand)?.action == .insertTableColumn(2) })
    let codeMenu = try #require(editor.makeBlockActionMenu(blockID: code.id))
    let children = codeMenu.items.flatMap { $0.submenu?.items ?? [] }
    let java = try #require(children.first { ($0.representedObject as? BlockMenuCommand)?.action == .codeLanguage(.java) })
    let selector = try #require(java.action)
    #expect(NSApplication.shared.sendAction(selector, to: java.target, from: java))
    #expect(editor.content.blocks.last?.language == .java && editor.content.blocks[2] == table)
    var copied = ""
    editor.writeCodeToPasteboard = { copied = $0; return true }
    #expect(editor.performBlockAction(.copyCode, blockID: code.id))
    #expect(copied == code.text)
}

@Test @MainActor func contextTableRowColumnEditsKeepDataAndUndo() throws {
    let table = NoteBlock(kind: .table, table: NoteTable(rows: [["A", "B"], ["C", "D"]], headerRow: true))
    let original = NoteContent(blocks: [table, NoteBlock(text: "after")])
    let editor = contextEditor(original)
    let delegate = ContextHistory(); delegate.history.groupsByEvent = false
    editor.delegate = delegate; editor.allowsUndo = true
    for action in [BlockAction.insertTableRow(1), .insertTableColumn(1), .deleteTableRow(0), .deleteTableColumn(0)] {
        delegate.history.beginUndoGrouping()
        #expect(editor.performBlockAction(action, blockID: table.id))
        delegate.history.endUndoGrouping()
        let changed = try #require(editor.content.blocks[0].table)
        switch action {
        case .insertTableRow: #expect(changed.rows == [["A", "B"], ["", ""], ["C", "D"]])
        case .insertTableColumn: #expect(changed.rows == [["A", "", "B"], ["C", "", "D"]])
        case .deleteTableRow: #expect(changed.rows == [["C", "D"]])
        default: #expect(changed.rows == [["B"], ["D"]])
        }
        #expect(changed.headerRow && editor.content.blocks[1] == original.blocks[1])
        try editor.content.validate()
        delegate.history.undo()
        #expect(editor.content == original)
    }
    editor.configure(content: NoteContent(blocks: [NoteBlock(kind: .table, table: NoteTable(rows: [["last"]]))]))
    let id = editor.content.blocks[0].id
    #expect(!editor.performBlockAction(.deleteTableRow(0), blockID: id))
    #expect(!editor.performBlockAction(.deleteTableColumn(0), blockID: id))
    #expect(!editor.performBlockAction(.insertTableColumn(5), blockID: id))
}

@Test @MainActor func contextDuplicateNotePersistsIndependentContentAndSharedAssets() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = NoteLibrary(directory: directory)
    let source = try #require(library.entries.first)
    let image = NoteImage(id: UUID(), name: "test.png", pixelWidth: 1, pixelHeight: 1)
    try FileManager.default.createDirectory(at: source.store.file.assetsURL, withIntermediateDirectories: true)
    for original in [true, false] { try Data([1, 2, 3]).write(to: source.store.file.imageURL(image.id, original: original)) }
    source.store.edit(NoteContent(blocks: [NoteBlock(text: "original", marks: [NoteTextMark(location: 0, length: 3, bold: true)]), NoteBlock(kind: .image, image: image)]))
    source.store.setColor(.green); source.store.setIcon("🌿")
    let copy = try #require(library.duplicateNote(source.id))
    #expect(copy.id != source.id && copy.store.document.color == .green && copy.store.document.icon == "🌿")
    #expect(copy.store.document.content.blocks.map(\.id) != source.store.document.content.blocks.map(\.id))
    #expect(copy.store.document.content.blocks[0].marks == source.store.document.content.blocks[0].marks)
    #expect(copy.store.document.content.blocks[1].image == image)
    copy.store.edit(NoteContent(plainText: "independent")); #expect(copy.store.flush())
    let restarted = NoteLibrary(directory: directory)
    #expect(restarted.entry(source.id)?.store.document.content == source.store.document.content)
    #expect(restarted.entry(copy.id)?.store.document.text == "independent")
    try FileManager.default.removeItem(at: source.store.file.imageURL(image.id))
    #expect(library.duplicateNote(source.id) == nil)
    #expect(library.entries.count == 2)
    #expect(try source.store.file.load() == source.store.document)
}
