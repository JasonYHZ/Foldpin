import AppKit
import Testing
@testable import FoldpinCore

@Test func actionsMenuAnchorsBottomRightAndStaysOnItsScreen() {
    let screen = CGRect(x: -1920, y: 100, width: 1920, height: 1080)
    let anchor = CGPoint(x: -300, y: 200)
    let frame = NoteActionsLayout.frame(anchor: anchor, width: 320, height: 360, screen: screen)
    #expect(frame.maxX == anchor.x && frame.minY == anchor.y)
    for point in [CGPoint(x: -1900, y: 1100), CGPoint(x: -2, y: 101)] {
        let fitted = NoteActionsLayout.frame(anchor: point, width: 320, height: 360, screen: screen)
        #expect(screen.insetBy(dx: 8, dy: 8).contains(fitted))
        #expect(fitted.size == CGSize(width: 320, height: 360))
    }
}

@Test @MainActor func recentlyDeletedSurvivesRestartAndRestoresImagesAndMetadata() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = NoteLibrary(directory: directory)
    let entry = try #require(library.entries.first)
    let image = NoteImage(id: UUID(), name: "test.png", pixelWidth: 1, pixelHeight: 1)
    try FileManager.default.createDirectory(at: entry.store.file.assetsURL, withIntermediateDirectories: true)
    for original in [false, true] { try Data("retained image".utf8).write(to: entry.store.file.imageURL(image.id, original: original)) }
    let content = NoteContent(blocks: [NoteBlock(text: "保留未落盘内容"), NoteBlock(kind: .image, image: image)])
    entry.store.edit(content)
    entry.store.setColor(.purple); entry.store.setIcon("🌿"); entry.store.setPinned(true); entry.store.setCollapsed(true)
    entry.store.setFrame(CGRect(x: -300, y: 90, width: 360, height: 340))
    let before = entry.store.document
    #expect(library.deleteNote(entry.id))
    #expect(library.entries.isEmpty && library.deletedEntries.first?.store === entry.store)
    library.reload()
    #expect(library.entries.isEmpty && library.deletedEntries.first?.store === entry.store)
    let reopened = NoteLibrary(directory: directory)
    #expect(reopened.entries.isEmpty && reopened.deletedEntries.count == 1)
    let restored = try #require(reopened.restoreNote(entry.id))
    #expect(restored.store.document == before)
    #expect(reopened.deletedEntries.isEmpty && reopened.entries.count == 1)
    #expect(try Data(contentsOf: entry.store.file.imageURL(image.id)) == Data("retained image".utf8))
    #expect(NoteLibrary(directory: directory).entry(entry.id)?.store.document == before)
}

@Test @MainActor func failedDeleteAndRestoreKeepTheirOriginalLifecycleState() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = NoteLibrary(directory: directory)
    let entry = try #require(library.entries.first)
    let image = NoteImage(id: UUID(), name: "missing.png", pixelWidth: 1, pixelHeight: 1)
    entry.store.edit(NoteContent(blocks: [NoteBlock(text: "keep me"), NoteBlock(kind: .image, image: image)]))
    #expect(!library.deleteNote(entry.id))
    #expect(library.entry(entry.id) != nil && library.deletedEntries.isEmpty)
    #expect(entry.store.document.deletedAt == nil && entry.store.saveError != nil)
    try FileManager.default.createDirectory(at: entry.store.file.assetsURL, withIntermediateDirectories: true)
    for original in [false, true] { try Data("fixture".utf8).write(to: entry.store.file.imageURL(image.id, original: original)) }
    #expect(library.deleteNote(entry.id))
    let date = entry.store.document.deletedAt
    try FileManager.default.removeItem(at: entry.store.file.imageURL(image.id))
    #expect(library.restoreNote(entry.id) == nil)
    #expect(library.entries.isEmpty && library.deletedEntries.count == 1)
    #expect(entry.store.document.deletedAt == date)
}

@Test @MainActor func copyAllPublishesRichImagesHTMLAndLosslessBlocks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = NoteFile(url: directory.appendingPathComponent("note.json"))
    let image = NoteImage(id: UUID(), name: "image <test>.png", pixelWidth: 2, pixelHeight: 2)
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try FileManager.default.createDirectory(at: file.assetsURL, withIntermediateDirectories: true)
    try png.write(to: file.imageURL(image.id))
    let content = NoteContent(blocks: [
        NoteBlock(kind: .heading, text: "标题 🌿", marks: [NoteTextMark(location: 0, length: 2, bold: true)]),
        NoteBlock(kind: .image, image: image),
        NoteBlock(kind: .table, table: NoteTable(rows: [["A", "<B>"], ["中文", "2"]], headerRow: true)),
        NoteBlock(kind: .code, text: "<script>print(1)</script>", language: .javascript),
        NoteBlock(text: "最后一段")])
    let board = NSPasteboard(name: NSPasteboard.Name("Foldpin-copy-test-\(UUID())"))
    defer { board.releaseGlobally() }
    try NoteClipboard.copy(content, file: file, to: board)
    #expect(board.string(forType: .string) == content.plainText)
    #expect(try JSONDecoder().decode(NoteContent.self, from: #require(board.data(forType: NoteClipboard.blocksType))) == content)
    let html = try #require(board.string(forType: .html))
    #expect(html.contains("data:image/png;base64,"))
    #expect(html.contains("<table") && html.contains("<strong>标题</strong>"))
    #expect(html.contains("&lt;script&gt;") && !html.contains("<script>"))
    #expect(!html.contains(directory.path))
    let rich = try NSAttributedString(data: #require(board.data(forType: .rtfd)), options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
    #expect(rich.string.contains("最后一段") && rich.string.contains("标题"))
    var attachmentCount = 0
    rich.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rich.length)) { value, _, _ in
        if let attachment = value as? NSTextAttachment, attachment.fileWrapper != nil { attachmentCount += 1 }
    }
    #expect(attachmentCount == 2)
    // An unreadable image must fail before disturbing an existing clipboard.
    try FileManager.default.removeItem(at: file.imageURL(image.id))
    #expect(throws: (any Error).self) { try NoteClipboard.copy(content, file: file, to: board) }
    #expect(board.string(forType: .string) == content.plainText)
}
