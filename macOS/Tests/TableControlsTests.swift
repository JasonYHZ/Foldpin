import AppKit
import Testing
@testable import FoldpinCore

@MainActor private final class TableUndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}

@MainActor private func tableEditor(_ content: NoteContent) -> (PaperTextView, NSScrollView) {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
    scroll.drawsBackground = false
    let view = PaperTextView(usingTextLayoutManager: true)
    view.frame = NSRect(x: 0, y: 0, width: 480, height: 800)
    view.textContainerInset = NSSize(width: 32, height: 16)
    view.textContainer?.lineFragmentPadding = 0
    view.textContainer?.size = NSSize(width: 416, height: 100_000)
    view.textContainer?.widthTracksTextView = true
    view.isRichText = true
    scroll.documentView = view
    view.configure(content: content)
    return (view, scroll)
}

@Test func tableHeaderFlagsDecodeOldTablesAndRoundTripNewTables() throws {
    let old = try JSONDecoder().decode(NoteTable.self, from: Data(#"{"rows":[["A","B"],["C","D"]]}"#.utf8))
    #expect(!old.headerRow && !old.headerColumn)
    var table = old; table.headerRow = true; table.headerColumn = true
    #expect(try JSONDecoder().decode(NoteTable.self, from: JSONEncoder().encode(table)) == table)
    #expect(table.isHeader(row: 0, column: 1) && table.isHeader(row: 1, column: 0))
    #expect(!table.isHeader(row: 1, column: 1))
}

@Test @MainActor func tableSettingsAndGrowthTargetTheChosenBlockWithUndo() throws {
    let first = NoteBlock(kind: .table, table: NoteTable(rows: [["A", "B"], ["C", "D"]]))
    let second = NoteBlock(kind: .table)
    let (view, scroll) = tableEditor(NoteContent(blocks: [first, second, NoteBlock(text: "after")]))
    defer { scroll.documentView = nil }
    let history = TableUndoDelegate()
    view.delegate = history; view.allowsUndo = true; history.history.groupsByEvent = false
    view.beginTableCellEditing(blockID: second.id, row: 0, column: 0)
    let before = view.content
    history.history.beginUndoGrouping()
    #expect(view.performBlockAction(.toggleHeaderRow, blockID: first.id))
    #expect(view.performBlockAction(.toggleHeaderColumn, blockID: first.id))
    history.history.endUndoGrouping()
    #expect(view.content.blocks[0].table?.headerRow == true && view.content.blocks[0].table?.headerColumn == true)
    #expect(view.content.blocks[1] == second)
    history.history.undo()
    #expect(view.content == before)
    history.history.redo()
    let headers = view.content
    for addingRow in [true, false] {
        history.history.beginUndoGrouping()
        #expect(view.addTableDimension(blockID: first.id, addingRow: addingRow))
        history.history.endUndoGrouping()
        let table = try #require(view.content.blocks[0].table)
        #expect(table.rows.count == (addingRow ? 3 : 2) && table.columnCount == (addingRow ? 2 : 3))
        #expect(table.rows[0][0] == "A" && table.rows[1][1] == "D" && table.headerRow && table.headerColumn)
        let cell = try #require(view.tableCellEditor)
        #expect(cell.string.isEmpty && cell.font == TableBlockLayout.headerFont)
        history.history.undo()
        #expect(view.content == headers && view.content.blocks[1] == second)
    }
    try view.content.validate()
    view.isEditable = false
    #expect(!view.addTableDimension(blockID: first.id, addingRow: true))
}

@Test @MainActor func tableControlsFollowGridScrollAndPassThroughCellClicks() throws {
    let block = NoteBlock(kind: .table, table: NoteTable(rows: [["Name", "Value"], ["First", "1"]], headerRow: true))
    let (view, scroll) = tableEditor(NoteContent(blocks: [block, NoteBlock(text: "following text")]))
    defer { scroll.documentView = nil }
    let grid = try #require(view.tableFrame(blockID: block.id))
    view.updateTableControls(at: NSPoint(x: grid.midX, y: grid.midY))
    let controls = try #require(view.tableControls)
    #expect(controls.superview === scroll && !controls.isHidden)
    #expect(!controls.rowButton.isHidden && !controls.columnButton.isHidden)
    let cellPoint = scroll.convert(NSPoint(x: grid.midX, y: grid.midY), from: view)
    #expect(controls.hitTest(cellPoint) == nil)
    let row = controls.rowButton.frame
    let rowPoint = scroll.convert(NSPoint(x: row.midX, y: row.midY), from: controls)
    #expect(controls.hitTest(rowPoint) === controls.rowButton)
    let rowInEditor = view.convert(row, from: controls)
    #expect(rowInEditor.minY > grid.maxY)
    let next = try #require(view.blockSurfaces().last)
    #expect(next.firstLine.minY > rowInEditor.maxY)
    // Direct button action adds to this table even if text selection is elsewhere.
    view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
    controls.rowButton.performClick(nil)
    #expect(view.content.blocks[0].table?.rows.count == 3 && view.tableCellEditor != nil)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
    view.updateTableControls(at: nil)
    #expect(controls.isHidden)
    scroll.contentView.scroll(to: .zero)
    view.updateTableControls(at: nil)
    #expect(view.tableControls === controls && !controls.isHidden)
}

@Test @MainActor func tableControlsCannotChangeStructureDuringComposition() throws {
    let block = NoteBlock(kind: .table)
    let (view, scroll) = tableEditor(NoteContent(blocks: [block, NoteBlock()]))
    defer { scroll.documentView = nil }
    view.beginTableCellEditing(blockID: block.id, row: 0, column: 0)
    let cell = try #require(view.tableCellEditor)
    cell.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: cell.selectedRange())
    view.updateTableControls(at: nil)
    #expect(view.tableControls?.rowButton.isEnabled == false)
    #expect(!view.addTableDimension(blockID: block.id, addingRow: false))
    #expect(view.tableCellEditor === cell && cell.hasMarkedText())
    cell.unmarkText()
    view.updateTableControls(at: nil)
    #expect(view.tableControls?.rowButton.isEnabled == true)
    #expect(view.content.blocks[0].table?.rows[0][0] == "中文")
}

@Test @MainActor func tableHeaderLayoutReuseMatchesFreshMeasurement() {
    var table = NoteTable(rows: [[String(repeating: "wide text ", count: 8), "header"], ["body", "value"]])
    let old = TableBlockLayout(table: table, width: 260)
    table.headerRow = true; table.headerColumn = true
    let updated = TableBlockLayout(table: table, width: 260, reusing: old)
    let fresh = TableBlockLayout(table: table, width: 260)
    #expect(updated.rowHeights == fresh.rowHeights && updated.size == fresh.size)
    #expect(updated.attachmentSize.height == updated.size.height + 24)
}
