import AppKit
import Testing
@testable import FoldpinCore

@MainActor private final class BlockActionsUndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}

@MainActor private func actionsEditor(_ content: NoteContent) -> PaperTextView {
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.frame = NSRect(x: 0, y: 0, width: 420, height: 360)
    editor.minSize = NSSize(width: 0, height: 360)
    editor.textContainerInset = NSSize(width: 32, height: 16)
    editor.textContainer?.size = NSSize(width: 356, height: CGFloat.greatestFiniteMagnitude)
    editor.textContainer?.widthTracksTextView = true
    editor.textContainer?.lineFragmentPadding = 0
    editor.isRichText = true
    editor.isAutomaticQuoteSubstitutionEnabled = false
    editor.configure(content: content)
    return editor
}

@Test @MainActor func blockActionsTargetIDsAndPreserveNativeUndo() throws {
    _ = NSApplication.shared
    let block = NoteBlock(text: "中文 🌿\u{2028}second", marks: [NoteTextMark(location: 0, length: 2, bold: true)])
    let original = NoteContent(blocks: [NoteBlock(text: "neighbor"), block, NoteBlock(kind: .code, text: "a\nb", language: .plain)])
    let editor = actionsEditor(original)
    let delegate = BlockActionsUndoDelegate()
    delegate.history.groupsByEvent = false
    editor.delegate = delegate; editor.allowsUndo = true
    for action in [BlockAction.moveUp, .moveDown, .duplicate, .convert(.heading), .delete] {
        editor.setSelectedRange(NSRange(location: 1, length: 0)) // Deliberately another block.
        delegate.history.beginUndoGrouping()
        #expect(editor.performBlockAction(action, blockID: block.id))
        delegate.history.endUndoGrouping()
        let changed = editor.content
        #expect(changed != original)
        #expect(changed.blocks.contains { $0 == original.blocks[0] })
        #expect(changed.blocks.contains { $0 == original.blocks[2] })
        if action == .duplicate {
            let copied = changed.blocks[2]
            #expect(copied.id != block.id && copied.text == block.text && copied.marks == block.marks)
            #expect(editor.selectedBlockID == copied.id)
        }
        #expect(try JSONDecoder().decode(NoteContent.self, from: JSONEncoder().encode(changed)) == changed)
        delegate.history.undo()
        #expect(editor.content == original && editor.selectedBlockID == nil)
        delegate.history.redo()
        #expect(editor.content == changed)
        delegate.history.undo()
    }
    #expect(!editor.performBlockAction(.delete, blockID: UUID()))
    #expect(!editor.performBlockAction(.moveUp, blockID: original.blocks[0].id))
    #expect(!editor.performBlockAction(.moveDown, blockID: original.blocks[2].id))
    #expect(editor.content == original)
}

@Test @MainActor func blockActionsMenuKeepsItsTargetAndCopyKeepsStructure() throws {
    let block = NoteBlock(kind: .task, text: "task", marks: [NoteTextMark(location: 0, length: 4, italic: true)], isChecked: true)
    let editor = actionsEditor(NoteContent(blocks: [NoteBlock(text: "before"), block]))
    editor.setSelectedRange(NSRange(location: 0, length: 0))
    let menu = try #require(editor.makeBlockActionMenu(blockID: block.id))
    let down = try #require(menu.items.first { ($0.representedObject as? BlockMenuCommand)?.action == .moveDown })
    #expect(!down.isEnabled)
    let heading = try #require(menu.items.compactMap(\.submenu).flatMap(\.items).first {
        ($0.representedObject as? BlockMenuCommand)?.action == .convert(.heading)
    })
    #expect((heading.representedObject as? BlockMenuCommand)?.blockID == block.id)
    #expect(NSApplication.shared.sendAction(try #require(heading.action), to: heading.target, from: heading))
    #expect(editor.content.blocks[0].text == "before" && editor.content.blocks[1].kind == .heading)
    var copied: NoteContent?
    editor.writeBlockToPasteboard = { copied = $0; return true }
    #expect(editor.selectBlock(block.id))
    editor.copy(nil)
    #expect(copied == NoteContent(blocks: [editor.content.blocks[1]]))
    let before = editor.content
    editor.writeBlockToPasteboard = { _ in false }
    editor.cut(nil)
    #expect(editor.content == before && editor.selectedBlockID == block.id)
    editor.writeBlockToPasteboard = { _ in true }
    editor.cut(nil)
    #expect(editor.content.blocks.count == 1 && editor.content.blocks[0].text == "before")
}

@Test @MainActor func blockActionsFinalDeletionAndImageReferencesUndoSafely() throws {
    let image = NoteImage(id: UUID(), name: "sample.png", pixelWidth: 60, pixelHeight: 40)
    for block in [NoteBlock(kind: .heading), NoteBlock(kind: .code, language: .swift), NoteBlock(kind: .image, image: image)] {
        let original = NoteContent(blocks: [block])
        let editor = actionsEditor(original)
        let delegate = BlockActionsUndoDelegate()
        delegate.history.groupsByEvent = false
        editor.delegate = delegate; editor.allowsUndo = true
        #expect(editor.selectBlock(block.id))
        delegate.history.beginUndoGrouping()
        editor.deleteBackward(nil)
        delegate.history.endUndoGrouping()
        #expect(editor.content.blocks.count == 1 && editor.content.blocks[0].kind == .paragraph && editor.content.isEmpty)
        #expect(editor.selectedBlockID == nil)
        delegate.history.undo()
        #expect(editor.content == original)
        delegate.history.redo()
        #expect(editor.content.blocks[0].kind == .paragraph && editor.content.isEmpty)
    }
    let block = NoteBlock(kind: .image, image: image)
    let editor = actionsEditor(NoteContent(blocks: [block]))
    #expect(!editor.performBlockAction(.convert(.paragraph), blockID: block.id))
    #expect(editor.performBlockAction(.duplicate, blockID: block.id))
    #expect(editor.content.blocks.count == 2 && editor.content.blocks.allSatisfy { $0.image == image })
    #expect(Set(editor.content.blocks.map(\.id)).count == 2)
    let before = editor.content
    editor.cancelOperation(nil)
    #expect(editor.content == before && editor.selectedBlockID == nil)
}

@Test @MainActor func blockSelectionEditingEscapeAndCompositionDoNotReplaceContent() throws {
    let first = NoteBlock(text: "First")
    let last = NoteBlock(kind: .code, text: "abc\ndef", language: .plain)
    let original = NoteContent(blocks: [first, last])
    let editor = actionsEditor(original)
    var shelved = 0
    editor.onEscape = { shelved += 1 }
    #expect(editor.selectBlock(first.id) && !editor.shouldDrawInsertionPoint)
    editor.moveDown(nil)
    #expect(editor.selectedBlockID == last.id && editor.content == original)
    editor.cancelOperation(nil)
    #expect(editor.selectedBlockID == nil && shelved == 0 && editor.content == original)
    editor.cancelOperation(nil)
    #expect(shelved == 1)
    editor.selectBlock(first.id)
    editor.insertNewline(nil)
    #expect(editor.content == original && editor.selectedBlockID == nil && editor.selectedRange().location == 5)
    editor.selectBlock(first.id)
    editor.insertText("!", replacementRange: editor.selectedRange())
    #expect(editor.content.blocks[0].text == "First!" && editor.content.blocks[1] == last)
    editor.selectBlock(first.id)
    editor.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
    #expect(editor.selectedBlockID == nil && editor.hasMarkedText())
    let marked = editor.attributedString()
    #expect(!editor.selectBlock(last.id) && !editor.performBlockAction(.delete, blockID: last.id))
    #expect(editor.makeBlockActionMenu(blockID: last.id) == nil && editor.attributedString().isEqual(to: marked))
    editor.unmarkText()
    #expect(editor.content.blocks[0].text == "First!中")
    editor.isEditable = false
    #expect(!editor.selectBlock(first.id) && !editor.performBlockAction(.delete, blockID: first.id))
}

@Test @MainActor func blockHandleGeometryReuseAndSelectionMatchWholeBlocks() throws {
    let paragraph = NoteBlock(text: String(repeating: "A wrapping paragraph. ", count: 8))
    let heading = NoteBlock(kind: .heading, text: "Block actions")
    let code = NoteBlock(kind: .code, text: "let a = 1\nprint(a)\n", language: .plain)
    let content = NoteContent(blocks: [paragraph, heading, code, NoteBlock()])
    let editor = actionsEditor(content)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
    scroll.drawsBackground = true
    scroll.backgroundColor = .textBackgroundColor
    scroll.documentView = editor
    let manager = try #require(editor.textLayoutManager)
    manager.ensureLayout(for: try #require(manager.textContentManager?.documentRange))
    let surfaces = editor.blockSurfaces()
    #expect(surfaces.count == 4)
    let prose = try #require(surfaces.first)
    #expect(prose.rect.height > prose.firstLine.height)
    editor.updateBlockHandle(at: NSPoint(x: prose.rect.midX, y: prose.rect.midY))
    let handle = try #require(editor.blockHandle)
    #expect(!handle.isHidden && handle.blockID == paragraph.id && handle.superview === scroll)
    #expect(editor.convert(handle.frame, from: scroll).maxX < prose.rect.minX)
    let title = try #require(surfaces.first { $0.blockID == heading.id })
    editor.updateBlockHandle(at: NSPoint(x: title.rect.midX, y: title.rect.midY))
    #expect(editor.blockHandle === handle && handle.blockID == heading.id)
    handle.updateTrackingAreas()
    let tracking = handle.trackingAreas
    editor.selectBlock(heading.id)
    for offset in [20.0, 21, 30] {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
        #expect(!handle.isHidden)
        editor.updateBlockHandle(at: nil)
        #expect(editor.blockHandle === handle && !handle.isHidden && handle.blockID == heading.id)
        handle.updateTrackingAreas()
        #expect(handle.trackingAreas == tracking)
    }
    #expect(editor.content == content && !editor.shouldDrawInsertionPoint)
    if let folder = ProcessInfo.processInfo.environment["FOLDPIN_BLOCK_ACTIONS_PREVIEW_DIR"] {
        let directory = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            scroll.appearance = NSAppearance(named: appearance)
            let bitmap = try #require(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
            scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("block-selection-\(appearance.rawValue).png"))
        }
    }
    editor.clearBlockSelection()
    editor.updateBlockHandle(at: nil)
    #expect(handle.isHidden)
}

@Test @MainActor func blockSelectionShortcutsAndSyntaxRefreshKeepTarget() async throws {
    let code = NoteBlock(kind: .code, text: "const selected = 42;", language: .javascript)
    let original = NoteContent(blocks: [NoteBlock(text: "Keep this neighbor"), code])
    let editor = actionsEditor(original)
    editor.selectBlock(code.id)
    editor.updateColors(.brown)
    await editor.syntaxTask?.value
    #expect(editor.selectedBlockID == code.id && editor.content == original)
    let duplicate = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .capsLock],
        timestamp: 0, windowNumber: 0, context: nil, characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2))
    #expect(editor.performKeyEquivalent(with: duplicate))
    #expect(editor.content.blocks.count == 3 && editor.selectedBlockID == editor.content.blocks[2].id)
    let delete = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
        timestamp: 0, windowNumber: 0, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
    editor.keyDown(with: delete)
    #expect(editor.content == original && editor.selectedBlockID == nil)
    editor.selectBlock(code.id)
    editor.selectAll(nil)
    #expect(editor.selectedBlockID == nil && editor.selectedRange().length == editor.string.utf16.count)
}
