import AppKit
import Testing
@testable import FoldpinCore

@Test @MainActor func blockDragTypeSurvivesNativeEditorLifecycle() {
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.isRichText = true
    editor.configure(content: NoteContent(blocks: [NoteBlock(text: "first"), NoteBlock(text: "last")]))
    #expect(editor.registeredDraggedTypes.contains(BlockReordering.pasteboardType))
    editor.isEditable = true
    #expect(editor.registeredDraggedTypes.contains(BlockReordering.pasteboardType))
    editor.isEditable = false
    editor.isEditable = true
    #expect(editor.registeredDraggedTypes.contains(BlockReordering.pasteboardType))
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
    scroll.documentView = editor
    #expect(editor.registeredDraggedTypes.contains(BlockReordering.pasteboardType))
    let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: true)
    window.contentView = scroll
    #expect(editor.registeredDraggedTypes.contains(BlockReordering.pasteboardType))
    window.contentView = nil
}

@Test @MainActor func blockDragHandleHitTestingUsesParentCoordinates() throws {
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.frame = NSRect(x: 0, y: 0, width: 420, height: 400)
    editor.textContainerInset = NSSize(width: 32, height: 16)
    editor.textContainer?.size = NSSize(width: 356, height: 1000)
    editor.isRichText = true
    editor.configure(content: NoteContent(blocks: [NoteBlock(text: "first"), NoteBlock(text: "last")]))
    let scroll = NSScrollView(frame: editor.frame)
    scroll.documentView = editor
    let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = scroll
    defer { window.contentView = nil }
    editor.textLayoutManager?.ensureLayout(for: editor.textLayoutManager!.documentRange)
    let surface = try #require(editor.blockSurfaces().first)
    editor.updateBlockHandle(at: NSPoint(x: 100, y: surface.firstLine.midY))
    let handle = try #require(scroll.subviews.compactMap { $0 as? BlockHandleButton }.first)
    #expect(!handle.isHidden)
    let point = handle.convert(NSPoint(x: 10, y: 13), to: nil)
    #expect(scroll.hitTest(scroll.superview?.convert(point, from: nil) ?? point) === handle)
}
