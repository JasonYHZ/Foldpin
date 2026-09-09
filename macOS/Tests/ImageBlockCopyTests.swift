import AppKit
import Testing
@testable import FoldpinCore

@Test @MainActor func imageBlockMenuAndCommandCCopyTheTargetImageWithoutEditing() throws {
    let image = NoteImage(id: UUID(), name: "photo.png", pixelWidth: 2, pixelHeight: 1)
    let block = NoteBlock(kind: .image, image: image)
    let content = NoteContent(blocks: [NoteBlock(text: "other block"), block])
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.isRichText = true
    editor.file = NoteFile(url: URL(fileURLWithPath: "/private/tmp/unused-image-copy-fixture.json"))
    editor.configure(content: content)
    editor.setSelectedRange(NSRange(location: 2, length: 0))
    let selection = editor.selectedRange()
    var copied: [NoteImage] = []
    editor.writeImageToPasteboard = { value, _ in copied.append(value) }
    let menu = try #require(editor.makeBlockActionMenu(blockID: block.id))
    let copy = try #require(menu.items.first { ($0.representedObject as? BlockMenuCommand)?.action == .copyImage })
    #expect(copy.image != nil && copy.keyEquivalent == "c")
    #expect(menu.items.first { ($0.representedObject as? BlockMenuCommand)?.action == .copy }?.keyEquivalent == "")
    let selector = try #require(copy.action)
    #expect(NSApplication.shared.sendAction(selector, to: copy.target, from: copy))
    #expect(copied == [image] && editor.content == content && editor.selectedRange() == selection)
    #expect(editor.selectBlock(block.id))
    let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
    #expect(editor.performKeyEquivalent(with: key))
    #expect(copied == [image, image] && editor.content == content && editor.selectedBlockID == block.id)
    var structured: NoteContent?
    editor.writeBlockToPasteboard = { structured = $0; return true }
    #expect(editor.performBlockAction(.copy, blockID: block.id))
    #expect(structured == NoteContent(blocks: [block]))
    let textMenu = try #require(editor.makeBlockActionMenu(blockID: content.blocks[0].id))
    #expect(!textMenu.items.contains { ($0.representedObject as? BlockMenuCommand)?.action == .copyImage })
    #expect(!editor.performBlockAction(.copyImage, blockID: UUID()))
    #expect(!editor.performBlockAction(.copyImage, blockID: content.blocks[0].id))
    var status: NoteEditorStatus?
    editor.onStatusChange = { status = $0 }
    editor.writeImageToPasteboard = { _, _ in throw CocoaError(.fileReadNoSuchFile) }
    #expect(!editor.performBlockAction(.copyImage, blockID: block.id))
    #expect(status == .imageCopyFailed && editor.content == content && editor.selectedBlockID == block.id)
}

@Test @MainActor func imageClipboardWritesPixelsAtOriginalSizeAndKeepsClipboardOnFailure() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = NoteFile(url: directory.appendingPathComponent("note.json"))
    let image = NoteImage(id: UUID(), name: "name-is-not-the-content.png", pixelWidth: 2, pixelHeight: 1)
    try FileManager.default.createDirectory(at: file.assetsURL, withIntermediateDirectories: true)
    func png(_ width: Int, _ height: Int) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
        let pixels = try #require(bitmap.bitmapData)
        for pixel in 0..<(width * height) {
            pixels[pixel * 4] = 25; pixels[pixel * 4 + 1] = 90
            pixels[pixel * 4 + 2] = 50; pixels[pixel * 4 + 3] = 128
        }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
    try png(8, 6).write(to: file.imageURL(image.id, original: true))
    try png(2, 1).write(to: file.imageURL(image.id))
    let board = NSPasteboard(name: NSPasteboard.Name("Foldpin-image-test-\(UUID())"))
    defer { board.releaseGlobally() }
    try NoteClipboard.copyImage(image, file: file, to: board)
    for type in [NSPasteboard.PasteboardType.png, .tiff] {
        let data = try #require(board.data(forType: type))
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(bitmap.pixelsWide == 8 && bitmap.pixelsHigh == 6)
        let color = try #require(bitmap.colorAt(x: 0, y: 0))
        #expect(abs(color.alphaComponent - 0.5) < 0.02)
    }
    #expect(NSImage(pasteboard: board) != nil)
    #expect(board.string(forType: .string) == nil && board.data(forType: NoteClipboard.blocksType) == nil)
    try FileManager.default.removeItem(at: file.imageURL(image.id, original: true))
    try NoteClipboard.copyImage(image, file: file, to: board)
    let previewData = try #require(board.data(forType: .png))
    let preview = try #require(NSBitmapImageRep(data: previewData))
    #expect(preview.pixelsWide == 2)
    let previous = board.data(forType: .png)
    let changeCount = board.changeCount
    try FileManager.default.removeItem(at: file.imageURL(image.id))
    #expect(throws: (any Error).self) { try NoteClipboard.copyImage(image, file: file, to: board) }
    #expect(board.changeCount == changeCount && board.data(forType: .png) == previous)
}
