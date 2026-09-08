import AppKit
import SwiftUI
import Testing
@testable import FoldpinCore

@MainActor private func findEditor(_ view: NSView) -> PaperTextView? {
    if let editor = view as? PaperTextView { return editor }
    return view.subviews.lazy.compactMap { findEditor($0) }.first
}

@MainActor private func snapshot(_ view: NSView, name: String) throws {
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLDPIN_CHECK_OUTPUT"]!)
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
}

@MainActor private func command(_ key: String, in panel: PaperPanel) throws -> Bool {
    panel.makeKey()
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: key,
        charactersIgnoringModifiers: key, isARepeat: false, keyCode: key == "m" ? 46 : 13))
    return panel.performKeyEquivalent(with: event)
}

@Test @MainActor func multiWindowLifecycle() async throws {
    // All app preferences belong to this helper's volatile domain.
    UserDefaults.standard.setVolatileDomain(["noteAppearance": "paper", "appLanguage": "en"], forName: UserDefaults.argumentDomain)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if ProcessInfo.processInfo.environment["FOLDPIN_CHECK_DARK"] == "1" {
        app.appearance = NSAppearance(named: .darkAqua)
    }
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLDPIN_CHECK_DATA"]!)
    let library = NoteLibrary(directory: directory)
    let a = try #require(library.entries.first)
    let b = try #require(library.createNote())
    let table = NoteBlock(kind: .table, table: NoteTable(rows: [["名称", "状态"], ["新建纸片", "已完成"], ["表格编辑", "可直接输入"]], headerRow: true))
    a.store.edit(NoteContent(blocks: [NoteBlock(kind: .subheading, text: "第一张纸片"), table, NoteBlock(text: "继续记录…")]))
    b.store.edit("第二张纸片\n拥有独立内容和窗口状态")
    #expect(a.store.flush() && b.store.flush())
    let screen = try #require(NSScreen.main, "This native check needs access to WindowServer.").visibleFrame
    let first = PaperWindowController(entry: a, initialFrame: NSRect(x: screen.minX + 40, y: screen.minY + 40, width: 480, height: 400))
    let second = PaperWindowController(entry: b, initialFrame: NSRect(x: screen.minX + 540, y: screen.minY + 70, width: 360, height: 340))
    defer { first.dispose(); second.dispose() }
    first.showPaper(focus: false); second.showPaper(focus: false)
    try await Task.sleep(for: .milliseconds(180))
    let firstEditor = try #require(findEditor(first.paper.contentView!))
    let secondEditor = try #require(findEditor(second.paper.contentView!))
    #expect(firstEditor !== secondEditor)
    let undo = try #require(firstEditor.undoManager)
    #expect(undo !== secondEditor.undoManager)
    // Window-level enter/exit must change only chrome, even on an inactive note.
    let surface = try #require(first.paper.contentView as? NoteWindowSurface)
    let originalFrame = first.paper.frame
    let originalContent = a.store.document.content
    let dragPoint = NSPoint(x: originalFrame.width / 2, y: originalFrame.height - NoteLayout.headerHeight / 2)
    let dragBefore = try #require(surface.titlebarDragRegion(at: dragPoint))
    let dragFrame = dragBefore.frame
    let pointer = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: NSPoint(x: 100, y: 100),
        modifierFlags: [], timestamp: 0, windowNumber: first.paper.windowNumber, context: nil,
        eventNumber: 0, trackingNumber: 0, userData: nil))
    let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: NSPoint(x: -10, y: -10),
        modifierFlags: [], timestamp: 0, windowNumber: first.paper.windowNumber, context: nil,
        eventNumber: 1, trackingNumber: 0, userData: nil))
    var transaction = Transaction(); transaction.disablesAnimations = true
    withTransaction(transaction) { surface.mouseEntered(with: pointer) }
    #expect(first.titlebarState.isPointerInside)
    try snapshot(surface, name: "titlebar-hover")
    #expect(surface.titlebarDragRegion(at: dragPoint) === dragBefore && dragBefore.frame == dragFrame)
    withTransaction(transaction) { surface.mouseExited(with: exit) }
    #expect(!first.titlebarState.isPointerInside)
    // Let SwiftUI finish the fade before capturing the inactive appearance.
    try await Task.sleep(for: .milliseconds(180))
    try snapshot(surface, name: "titlebar-idle")
    #expect(first.paper.frame == originalFrame && a.store.document.content == originalContent)
    #expect(findEditor(surface) === firstEditor && firstEditor.undoManager === undo)
    #expect(surface.titlebarDragRegion(at: dragPoint) === dragBefore && dragBefore.frame == dragFrame)
    undo.groupsByEvent = false
    undo.beginUndoGrouping()
    firstEditor.setSelectedRange(NSRange(location: (firstEditor.string as NSString).length, length: 0))
    firstEditor.insertText("独立修改", replacementRange: firstEditor.selectedRange())
    undo.endUndoGrouping()
    let edited = a.store.document.content
    let untouched = b.store.document
    first.togglePin()
    withTransaction(transaction) { surface.mouseEntered(with: pointer) }
    try await Task.sleep(for: .milliseconds(180))
    try snapshot(surface, name: "titlebar-pinned")
    #expect(try command("m", in: first.paper))
    try await Task.sleep(for: .milliseconds(80))
    #expect(a.store.isCollapsed && !b.store.isCollapsed && a.store.document.isPinned && !b.store.document.isPinned)
    #expect(first.paper.frame.height == NoteLayout.headerHeight)
    #expect(findEditor(first.paper.contentView!) === firstEditor)
    withTransaction(transaction) { surface.mouseEntered(with: pointer) }
    try snapshot(surface, name: "titlebar-collapsed")
    first.toggleCollapsed()
    #expect(try command("w", in: first.paper))
    #expect(a.store.document.isShelved && !first.isVisible && second.isVisible)
    #expect(b.store.document == untouched)
    first.showPaper(focus: false)
    try await Task.sleep(for: .milliseconds(80))
    #expect(findEditor(first.paper.contentView!) === firstEditor && firstEditor.undoManager === undo)
    undo.undo()
    #expect(firstEditor.content != edited && b.store.document == untouched)
    undo.redo()
    #expect(firstEditor.content == edited)
    firstEditor.beginTableCellEditing(blockID: table.id, row: 2, column: 1)
    firstEditor.updateTableControls(at: nil)
    let controls = try #require(firstEditor.tableControls)
    #expect(!controls.rowButton.isHidden && !controls.columnButton.isHidden)
    first.paper.contentView?.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(80))
    try snapshot(first.paper.contentView!, name: "table-controls")
    let shelf = NSHostingView(rootView: ShelfView(library: library, onOpen: { _ in }, onNew: {}, onRetry: {}))
    let shelfPanel = NSPanel(contentRect: NSRect(x: screen.minX + 80, y: screen.minY + 80, width: 320, height: 310),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    shelfPanel.isReleasedWhenClosed = false
    shelfPanel.contentView = shelf
    shelfPanel.backgroundColor = .windowBackgroundColor
    shelfPanel.orderFrontRegardless()
    defer { shelfPanel.orderOut(nil); shelfPanel.contentView = nil; shelfPanel.close() }
    try await Task.sleep(for: .milliseconds(80))
    try snapshot(shelf, name: "multi-note-shelf")
    first.toggleCollapsed()
    second.paper.performClose(nil)
    #expect(first.prepareToTerminate() && second.prepareToTerminate())
    let expectedA = a.store.document
    let expectedB = b.store.document
    let reopened = NoteLibrary(directory: directory)
    #expect(reopened.entry(a.id)?.store.document == expectedA)
    #expect(reopened.entry(b.id)?.store.document == expectedB)
    let restored = PaperWindowController(entry: try #require(reopened.entry(a.id)))
    defer { restored.dispose() }
    #expect(restored.paper.frame.height == NoteLayout.headerHeight)
    #expect(restored.paper.level == .floating && restored.store.document.frame == expectedA.frame)
    #expect(reopened.entry(b.id)?.store.document.isShelved == true)
    // Saving failure keeps the affected window and content visible.
    restored.showPaper(focus: false)
    let bytes = try Data(contentsOf: restored.store.file.url)
    try FileManager.default.removeItem(at: restored.store.file.url)
    try FileManager.default.createDirectory(at: restored.store.file.url, withIntermediateDirectories: false)
    restored.store.edit("不能丢失的内容")
    #expect(!restored.shelvePaper() && restored.isVisible && !restored.store.document.isShelved)
    #expect(restored.store.document.text == "不能丢失的内容" && restored.store.saveError != nil)
    try FileManager.default.removeItem(at: restored.store.file.url)
    try bytes.write(to: restored.store.file.url)
    #expect(restored.store.flush())
}
