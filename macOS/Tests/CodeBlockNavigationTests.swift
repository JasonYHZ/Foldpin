import AppKit
import Testing
@testable import FoldpinCore

@MainActor private final class NavigationUndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}

@MainActor private func navigationEditor(_ content: NoteContent) -> PaperTextView {
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.frame = NSRect(x: 0, y: 0, width: 440, height: 500)
    editor.textContainerInset = NSSize(width: 20, height: 16)
    editor.textContainer?.size = NSSize(width: 400, height: 100_000)
    editor.textContainer?.widthTracksTextView = true
    editor.isRichText = true
    editor.configure(content: content)
    return editor
}

@Test @MainActor func codeBoundaryArrowsCreateParagraphsWithNativeUndo() throws {
    let movements: [(Bool, (PaperTextView) -> Void)] = [
        (false, { $0.moveDown(nil) }), (false, { $0.moveRight(nil) }),
        (true, { $0.moveUp(nil) }), (true, { $0.moveLeft(nil) })
    ]
    for source in ["let value = 42\n// 中文 🌿", "let value = 42\n", ""] {
        for (before, move) in movements {
            let code = NoteBlock(kind: .code, text: source, language: .swift)
            let original = NoteContent(blocks: [code])
            let editor = navigationEditor(original)
            let delegate = NavigationUndoDelegate()
            delegate.history.groupsByEvent = false
            editor.delegate = delegate; editor.allowsUndo = true
            editor.setSelectedRange(NSRange(location: before ? 0 : source.utf16.count, length: 0))
            delegate.history.beginUndoGrouping()
            move(editor)
            delegate.history.endUndoGrouping()
            #expect(editor.content.blocks.count == 2)
            #expect(editor.content.blocks[before ? 1 : 0] == code)
            #expect(editor.currentBlockKind == .paragraph)
            #expect(editor.typingAttributes[.blockLanguage] as? String == "plain")
            let escaped = editor.content
            delegate.history.beginUndoGrouping()
            editor.insertText("继续写正文", replacementRange: editor.selectedRange())
            delegate.history.endUndoGrouping()
            #expect(editor.content.blocks[before ? 0 : 1].text == "继续写正文")
            #expect(editor.content.blocks[before ? 1 : 0] == code)
            #expect(try JSONDecoder().decode(NoteContent.self, from: JSONEncoder().encode(editor.content)) == editor.content)
            delegate.history.undo()
            #expect(editor.content == escaped)
            delegate.history.undo()
            #expect(editor.content == original)
            delegate.history.redo()
            #expect(editor.content == escaped)
        }
    }
}

@Test @MainActor func codeBoundaryNavigationKeepsExistingTextAndNormalCodeEditing() throws {
    let code = NoteBlock(kind: .code, text: "first\nsecond", language: .plain)
    let before = NoteBlock(text: "Before"), after = NoteBlock(text: "After")
    let original = NoteContent(blocks: [before, code, after])
    let editor = navigationEditor(original)
    let codeStart = before.text.utf16.count + 1
    editor.setSelectedRange(NSRange(location: codeStart, length: 0))
    editor.moveLeft(nil)
    #expect(editor.currentBlockKind == .paragraph && editor.content == original)
    editor.setSelectedRange(NSRange(location: codeStart + code.text.utf16.count, length: 0))
    editor.moveRight(nil)
    #expect(editor.currentBlockKind == .paragraph && editor.content == original)
    // Wrapped lines and interior character movement never create extra blocks.
    editor.configure(content: NoteContent(blocks: [code]))
    editor.setSelectedRange(NSRange(location: 2, length: 0))
    editor.moveRight(nil)
    #expect(editor.currentBlockKind == .code && editor.content.blocks.count == 1)
    editor.insertNewline(nil)
    #expect(editor.content.blocks.count == 1 && editor.content.blocks[0].text == "fir\nst\nsecond")
    // Extending a selection to the edge is not an exit gesture.
    editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
    let current = editor.content
    editor.moveRightAndModifySelection(nil)
    #expect(editor.content == current)
}

@Test @MainActor func codeBoundaryCommandReturnReusesParagraphAndSupportsKeypadAndCapsLock() throws {
    for keyCode: UInt16 in [36, 76] {
        let code = NoteBlock(kind: .code, text: "<div>🌿</div>", language: .html)
        let next = NoteBlock(text: "Existing paragraph")
        let original = NoteContent(blocks: [code, next])
        let editor = navigationEditor(original)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .capsLock, .numericPad], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: keyCode))
        #expect(editor.performKeyEquivalent(with: event))
        #expect(editor.content == original && editor.currentBlockKind == .paragraph)
        #expect(editor.selectedRange().location == code.text.utf16.count + 1)
    }
}

@Test @MainActor func codeBoundaryBlankSpaceClicksCreateParagraphOutsideCode() throws {
    for before in [false, true] {
        let code = NoteBlock(kind: .code, text: "first\nsecond\n", language: .plain)
        let original = NoteContent(blocks: [code])
        let editor = navigationEditor(original)
        let scroll = NSScrollView(frame: editor.frame)
        scroll.documentView = editor
        let delegate = NavigationUndoDelegate()
        delegate.history.groupsByEvent = false
        editor.delegate = delegate; editor.allowsUndo = true
        let surface = try #require(editor.codeBlockSurfaces().first).rect
        let point = NSPoint(x: 80, y: before ? surface.minY - 5 : surface.maxY + 15)
        #expect(editor.visibleRect.contains(point))
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: editor.convert(point, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        delegate.history.beginUndoGrouping()
        editor.mouseDown(with: event)
        delegate.history.endUndoGrouping()
        #expect(editor.content.blocks.count == 2 && editor.currentBlockKind == .paragraph)
        #expect(editor.content.blocks[before ? 1 : 0] == code)
        delegate.history.undo()
        #expect(editor.content == original)
    }
}

@Test @MainActor func codeBoundaryExitDoesNotMutateReadOnlyTextOrComposition() throws {
    let original = NoteContent(blocks: [NoteBlock(kind: .code, text: "value", language: .plain)])
    let editor = navigationEditor(original)
    editor.isEditable = false
    editor.moveDown(nil)
    editor.moveRight(nil)
    #expect(editor.content == original)
    editor.isEditable = true
    editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
    let draft = editor.attributedString(), content = editor.content, marked = editor.markedRange()
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    _ = editor.performKeyEquivalent(with: event)
    #expect(editor.content == content && editor.hasMarkedText() && editor.markedRange() == marked)
    #expect(editor.attributedString().isEqual(to: draft))
}
