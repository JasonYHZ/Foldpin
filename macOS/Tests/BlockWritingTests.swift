import AppKit
import Testing
@testable import FoldpinCore

@MainActor private final class BlockWritingUndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}

@MainActor private func writingEditor(_ content: NoteContent) -> PaperTextView {
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.frame = NSRect(x: 0, y: 0, width: 420, height: 380)
    editor.isRichText = true
    editor.isAutomaticQuoteSubstitutionEnabled = false
    editor.textContainerInset = NSSize(width: 20, height: 16)
    editor.textContainer?.size = NSSize(width: 380, height: CGFloat.greatestFiniteMagnitude)
    editor.configure(content: content)
    return editor
}

@Test @MainActor func blockWritingReturnExitsEmptyHeadingsAndContinuesLists() {
    for kind in [NoteBlockKind.heading, .subheading, .heading3, .heading4, .bullet, .orderedList, .task, .quote] {
        let empty = NoteBlock(kind: kind)
        let editor = writingEditor(NoteContent(blocks: [empty]))
        editor.insertNewline(nil)
        #expect(editor.content.blocks.count == 1)
        #expect(editor.content.blocks[0].id == empty.id)
        #expect(editor.content.blocks[0].kind == .paragraph)
        #expect(editor.string.isEmpty)
    }
    for kind in [NoteBlockKind.paragraph, .heading, .subheading, .heading3, .heading4, .bullet, .orderedList, .task, .quote] {
        let editor = writingEditor(NoteContent(blocks: [NoteBlock(kind: kind, text: "first", isChecked: true)]))
        editor.insertNewline(nil)
        #expect(editor.content.blocks.count == 2)
        let expected: NoteBlockKind = [.bullet, .orderedList, .task, .quote].contains(kind) ? kind : .paragraph
        #expect(editor.content.blocks[1].kind == expected)
        #expect(!editor.content.blocks[1].isChecked)
        #expect(editor.content.blocks[0].text == "first")
    }
}

@Test @MainActor func blockWritingSoftBreakKeepsOneBlockFormattingUndoAndSavedContent() throws {
    for kind in [NoteBlockKind.paragraph, .heading, .subheading, .heading3, .heading4, .bullet, .orderedList, .task, .quote, .code] {
        let block = NoteBlock(kind: kind, text: "中文 🌿", marks: kind == .code ? [] : [NoteTextMark(location: 0, length: 2, bold: true)])
        let editor = writingEditor(NoteContent(blocks: [block]))
        let delegate = BlockWritingUndoDelegate()
        delegate.history.groupsByEvent = false
        editor.delegate = delegate
        editor.allowsUndo = true
        let source = editor.content
        delegate.history.beginUndoGrouping()
        editor.insertLineBreak(nil)
        editor.insertText("next", replacementRange: editor.selectedRange())
        delegate.history.endUndoGrouping()
        #expect(editor.content.blocks.count == 1)
        #expect(editor.content.blocks[0].id == block.id && editor.content.blocks[0].kind == kind)
        #expect(editor.content.blocks[0].text == "中文 🌿" + (kind == .code ? "\n" : "\u{2028}") + "next")
        #expect(kind == .code || editor.content.blocks[0].marks.first == block.marks.first)
        let saved = editor.content
        #expect(try JSONDecoder().decode(NoteContent.self, from: JSONEncoder().encode(saved)) == saved)
        let restored = writingEditor(saved)
        #expect(restored.content == saved && restored.string == editor.string)
        delegate.history.undo()
        #expect(editor.content == source)
        delegate.history.redo()
        #expect(editor.content == saved)
    }
}

@Test @MainActor func blockWritingPlaceholdersNeverBecomeContentOrCoverComposition() throws {
    let content = NoteContent(blocks: [NoteBlock(text: "Title"), NoteBlock(kind: .heading),
                                      NoteBlock(kind: .subheading), NoteBlock(kind: .heading3), NoteBlock(kind: .heading4),
                                      NoteBlock(kind: .bullet), NoteBlock(kind: .task),
                                      NoteBlock(kind: .quote), NoteBlock(kind: .code), NoteBlock()])
    let editor = writingEditor(content)
    let originalString = editor.string
    let selection = editor.selectedRange()
    let manager = try #require(editor.textLayoutManager)
    manager.ensureLayout(for: try #require(manager.textContentManager?.documentRange))
    let placeholders = editor.blockPlaceholders()
    #expect(Set(placeholders.map(\.blockID)) == Set(content.blocks.dropFirst().map(\.id)))
    #expect(placeholders.allSatisfy { $0.rect.width > 0 && $0.rect.height > 0 })
    for pair in zip(placeholders, placeholders.dropFirst()) {
        #expect(pair.0.rect.maxY <= pair.1.rect.minY + 1)
    }
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        editor.appearance = NSAppearance(named: appearance)
        let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
        editor.cacheDisplay(in: editor.bounds, to: bitmap)
        if let folder = ProcessInfo.processInfo.environment["FOLDPIN_BLOCK_PREVIEW_DIR"] {
            let directory = URL(fileURLWithPath: folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("placeholders-\(appearance.rawValue).png"))
        }
    }
    #expect(editor.string == originalString && editor.content == content && editor.selectedRange() == selection)
    #expect(try JSONDecoder().decode(NoteContent.self, from: JSONEncoder().encode(editor.content)) == content)
    editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
    #expect(!editor.blockPlaceholders().contains { $0.blockID == content.blocks.last?.id })
    editor.unmarkText()
    #expect(editor.content.blocks.last?.text == "中文")
    let emptyEditor = writingEditor(NoteContent())
    #expect(emptyEditor.content.isEmpty)
    #expect(emptyEditor.blockPlaceholders().count == 1)
    #expect(emptyEditor.string.isEmpty && emptyEditor.content.isEmpty)
}

@Test @MainActor func blockWritingChineseFenceAcceptsSpaceAndPreservesLiteralPaste() {
    for fence in ["···", "···js", "｀｀｀"] {
        let editor = writingEditor(NoteContent())
        editor.insertText(fence, replacementRange: editor.selectedRange())
        editor.insertText(" ", replacementRange: editor.selectedRange())
        #expect(editor.content.blocks[0].kind == .code && editor.content.blocks[0].text.isEmpty)
        #expect(editor.content.blocks[0].language == (fence == "···js" ? .javascript : .automatic))
        let pasted = writingEditor(NoteContent())
        pasted.insertPastedText(fence + " ")
        #expect(pasted.content.blocks[0].kind == .paragraph && pasted.content.plainText == fence + " ")
    }
}

@Test @MainActor func blockWritingShiftReturnShortcutKeepsCompositionAndReadOnlySafe() throws {
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift, .capsLock],
                                            timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
                                            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    let editor = writingEditor(NoteContent(blocks: [NoteBlock(kind: .heading, text: "Title")]))
    #expect(editor.performKeyEquivalent(with: event))
    #expect(editor.content.blocks.count == 1 && editor.content.blocks[0].text == "Title\u{2028}")
    editor.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
    let marked = editor.attributedString()
    _ = editor.performKeyEquivalent(with: event)
    #expect(editor.hasMarkedText() && editor.attributedString().isEqual(to: marked))
    editor.unmarkText()
    editor.isEditable = false
    let readOnly = editor.content
    _ = editor.performKeyEquivalent(with: event)
    editor.insertLineBreak(nil)
    #expect(editor.content == readOnly)
}
