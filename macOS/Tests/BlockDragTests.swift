import AppKit
import Testing
@testable import FoldpinCore

@MainActor private final class DragUndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}

@MainActor private func dragEditor(_ content: NoteContent) -> PaperTextView {
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.frame = NSRect(x: 0, y: 0, width: 420, height: 480)
    editor.minSize = NSSize(width: 0, height: 480)
    editor.isRichText = true
    editor.textContainerInset = NSSize(width: 32, height: 16)
    editor.textContainer?.widthTracksTextView = true
    editor.textContainer?.lineFragmentPadding = 0
    editor.textContainer?.size = NSSize(width: 356, height: CGFloat.greatestFiniteMagnitude)
    editor.configure(content: content)
    if let manager = editor.textLayoutManager { manager.ensureLayout(for: manager.documentRange) }
    return editor
}

@MainActor private func point(_ editor: PaperTextView, block: UUID, below: Bool) throws -> NSPoint {
    let surface = try #require(editor.blockSurfaces().first { $0.blockID == block })
    return NSPoint(x: surface.rect.midX, y: below ? surface.rect.maxY - 1 : surface.rect.minY + 1)
}

@Test @MainActor func blockDragMovesWholeRichBlocksBothWaysAndPersistsOneUndoStep() throws {
    let marked = NoteBlock(text: "中文 🌿", marks: [NoteTextMark(location: 0, length: 2, bold: true)])
    let code = NoteBlock(kind: .code, text: "let a = 1\nprint(a)\n", language: .swift)
    let table = NoteBlock(kind: .table, table: NoteTable(rows: [["名称", "状态"], ["item", "done"]]))
    let initial = NoteContent(blocks: [marked, code, table, NoteBlock(kind: .divider), NoteBlock(kind: .task, text: "task", isChecked: true)])
    let editor = dragEditor(initial)
    let delegate = DragUndoDelegate()
    delegate.history.groupsByEvent = false
    editor.delegate = delegate; editor.allowsUndo = true
    let lastID = try #require(initial.blocks.last?.id)
    for (source, target, below) in [(marked.id, lastID, true), (table.id, marked.id, false), (code.id, lastID, true)] {
        #expect(editor.prepareBlockDrag(blockID: source) != nil)
        let location = try point(editor, block: target, below: below)
        #expect(editor.updateBlockDrop(at: location) != nil)
        #expect(editor.content == initial && !delegate.history.canUndo)
        #expect(editor.finishBlockDrag(at: location))
        let moved = editor.content
        #expect(moved.blocks.count == initial.blocks.count)
        #expect(Set(moved.blocks.map(\.id)) == Set(initial.blocks.map(\.id)))
        for block in initial.blocks { #expect(moved.blocks.contains(block)) }
        #expect(editor.selectedBlockID == source && editor.blockDropTarget == nil && editor.blockDragState == nil)
        if below { #expect(moved.blocks.last?.id == source) }
        else { #expect(moved.blocks.first?.id == source) }
        delegate.history.undo()
        #expect(editor.content == initial && !delegate.history.canUndo)
        delegate.history.redo()
        #expect(editor.content == moved)
        delegate.history.undo()
        delegate.history.removeAllActions()
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NoteStore(file: NoteFile(url: directory.appendingPathComponent("note.json")))
    editor.onContentChange = { store.edit($0) }
    #expect(editor.prepareBlockDrag(blockID: table.id) != nil)
    #expect(editor.finishBlockDrag(at: try point(editor, block: lastID, below: true)))
    #expect(store.flush())
    #expect(try store.file.load().content == editor.content)
}

@Test @MainActor func blockDragImageAndNumberingKeepIdentityAndNoOpDoesNotSave() throws {
    let image = NoteBlock(kind: .image, image: NoteImage(id: UUID(), name: "sample.png", pixelWidth: 120, pixelHeight: 40))
    let a = NoteBlock(kind: .orderedList, text: "first")
    let b = NoteBlock(kind: .orderedList, text: "second")
    let original = NoteContent(blocks: [image, a, b])
    let editor = dragEditor(original)
    var publications = 0
    editor.onContentChange = { _ in publications += 1 }
    #expect(editor.prepareBlockDrag(blockID: image.id) != nil)
    #expect(editor.updateBlockDrop(at: try point(editor, block: a.id, below: false)) == nil)
    #expect(!editor.finishBlockDrag(at: try point(editor, block: a.id, below: false)))
    #expect(editor.content == original && publications == 0)
    #expect(editor.prepareBlockDrag(blockID: image.id) != nil)
    #expect(editor.finishBlockDrag(at: try point(editor, block: b.id, below: true)))
    #expect(editor.content.blocks == [a, b, image])
    #expect(editor.string.hasPrefix("1. first\n2. second\n"))
    #expect(editor.prepareBlockDrag(blockID: b.id) != nil)
    #expect(editor.finishBlockDrag(at: try point(editor, block: a.id, below: false)))
    #expect(editor.string.hasPrefix("1. second\n2. first\n"))
    #expect(editor.content.blocks.last == image)
}

@Test @MainActor func blockDragCancelOutsideReadOnlyAndChangedDocumentCannotMove() throws {
    let original = NoteContent(blocks: [NoteBlock(text: "first"), NoteBlock(text: "last")])
    let editor = dragEditor(original)
    let first = original.blocks[0].id
    let last = original.blocks[1].id
    #expect(editor.prepareBlockDrag(blockID: first) != nil)
    #expect(editor.updateBlockDrop(at: try point(editor, block: last, below: true)) != nil)
    editor.cancelBlockDrag()
    #expect(editor.content == original && editor.blockDropTarget == nil)
    #expect(editor.prepareBlockDrag(blockID: first) != nil)
    #expect(!editor.finishBlockDrag(at: NSPoint(x: -20, y: -20)))
    #expect(editor.content == original)
    #expect(editor.prepareBlockDrag(blockID: first) != nil)
    editor.isEditable = false
    #expect(!editor.finishBlockDrag(at: try point(editor, block: last, below: true)))
    #expect(editor.prepareBlockDrag(blockID: first) == nil)
    editor.isEditable = true
    #expect(editor.prepareBlockDrag(blockID: first) != nil)
    var external = original
    external.blocks.append(NoteBlock(text: "new external content"))
    editor.loadExternalContent(external)
    #expect(!editor.finishBlockDrag(at: try point(editor, block: last, below: true)))
    #expect(editor.content == external)
    #expect(editor.prepareBlockDrag(blockID: UUID()) == nil)
    editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
    #expect(editor.prepareBlockDrag(blockID: first) == nil)
    #expect(editor.hasMarkedText())
}

@Test @MainActor func blockDragClickAndThresholdKeepMenuAndSourceStable() throws {
    let handle = BlockHandleButton()
    handle.blockID = UUID()
    var clicks = 0, starts = 0
    handle.onOpen = { _, _ in clicks += 1 }
    // Decline a system session in this offscreen pointer-dispatch check.
    handle.onPrepareDrag = { _ in starts += 1; return nil }
    func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    handle.mouseDown(with: try event(.leftMouseDown, 10, 13))
    #expect(handle.isTrackingPointer)
    handle.mouseDragged(with: try event(.leftMouseDragged, 12, 14))
    #expect(starts == 0)
    handle.mouseUp(with: try event(.leftMouseUp, 12, 14))
    #expect(clicks == 1 && !handle.isTrackingPointer)
    handle.mouseDown(with: try event(.leftMouseDown, 10, 13))
    handle.mouseDragged(with: try event(.leftMouseDragged, 10, 23))
    handle.mouseDragged(with: try event(.leftMouseDragged, 10, 24))
    handle.mouseUp(with: try event(.leftMouseUp, 10, 23))
    #expect(starts == 1 && clicks == 1 && !handle.isTrackingPointer)
}

@Test @MainActor func blockDragAutoscrollAndDropFeedbackUseScrolledCoordinates() throws {
    let original = NoteContent(blocks: (0..<30).map { NoteBlock(text: "Block \($0)\u{2028}second line") })
    let editor = dragEditor(original)
    editor.isVerticallyResizable = true
    editor.frame.size.height = 1800
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
    scroll.drawsBackground = true
    scroll.backgroundColor = .textBackgroundColor
    scroll.documentView = editor
    editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
    let first = original.blocks[0].id
    #expect(editor.prepareBlockDrag(blockID: first) != nil)
    #expect(editor.scrollBlockDrag(at: NSPoint(x: 100, y: editor.visibleRect.maxY - 2)))
    #expect(scroll.contentView.bounds.minY > 0)
    #expect(!editor.scrollBlockDrag(at: NSPoint(x: 100, y: editor.visibleRect.midY)))
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
    editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
    let surface = try #require(editor.blockSurfaces().first { $0.rect.midY > editor.visibleRect.minY + 35 && $0.rect.maxY < editor.visibleRect.maxY - 35 })
    let location = NSPoint(x: 100, y: surface.rect.minY + 1)
    let target = try #require(editor.updateBlockDrop(at: location))
    #expect(target.beforeBlockID == surface.blockID)
    #expect(editor.visibleRect.contains(target.indicator))
    #expect(editor.content == original)
    #expect(editor.finishBlockDrag(at: location))
    let before = try #require(editor.content.blocks.firstIndex(where: { $0.id == surface.blockID }))
    #expect(editor.content.blocks[before - 1].id == first)
    #expect(editor.content.blocks.count == original.blocks.count)
    if let folder = ProcessInfo.processInfo.environment["FOLDPIN_DRAG_PREVIEW_DIR"] {
        let directory = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            // Appearance snapshots get their own surface; cacheDisplay can
            // adjust a detached text view's viewport while rasterizing it.
            let preview = dragEditor(NoteContent(blocks: Array(original.blocks.prefix(4))))
            let container = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
            container.appearance = NSAppearance(named: name)
            container.drawsBackground = true
            container.backgroundColor = .textBackgroundColor
            container.documentView = preview
            preview.textLayoutManager?.textViewportLayoutController.layoutViewport()
            #expect(preview.prepareBlockDrag(blockID: first) != nil)
            _ = preview.updateBlockDrop(at: try point(preview, block: original.blocks[2].id, below: false))
            let bitmap = try #require(container.bitmapImageRepForCachingDisplay(in: container.bounds))
            container.cacheDisplay(in: container.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("block-drag-\(name.rawValue).png"))
        }
    }
}
