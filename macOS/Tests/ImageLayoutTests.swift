import AppKit
import Testing
@testable import FoldpinCore

@MainActor private final class ImageUndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}
@MainActor private func imageEditor(_ content: NoteContent, file: NoteFile? = nil) -> (PaperTextView, NSWindow, ImageUndoDelegate) {
    _ = NSApplication.shared
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.frame = NSRect(x: 0, y: 0, width: 420, height: 420)
    editor.textContainerInset = NSSize(width: 32, height: 8)
    editor.textContainer?.size = NSSize(width: 356, height: CGFloat.greatestFiniteMagnitude)
    editor.textContainer?.widthTracksTextView = true; editor.textContainer?.lineFragmentPadding = 0
    editor.file = file
    editor.isRichText = true; editor.configure(content: content)
    let delegate = ImageUndoDelegate(); delegate.history.groupsByEvent = false
    editor.delegate = delegate; editor.allowsUndo = true
    let window = NSWindow(contentRect: editor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame: editor.frame); scroll.documentView = editor; window.contentView = scroll
    editor.textLayoutManager?.ensureLayout(for: editor.textLayoutManager!.textContentManager!.documentRange)
    scroll.layoutSubtreeIfNeeded()
    return (editor, window, delegate)
}

@Test @MainActor func imageGeometryPreservesAspectAndFitsWithoutRewritingPreference() throws {
    var image = NoteImage(id: UUID(), name: "wide", pixelWidth: 1200, pixelHeight: 600)
    #expect(ImageBlockLayout(image: image, availableWidth: 360).imageSize == NSSize(width: 360, height: 180))
    image.displayWidth = 240; image.caption = "标题"
    let layout = ImageBlockLayout(image: image, availableWidth: 360)
    #expect(layout.imageSize == NSSize(width: 240, height: 120) && layout.size.height == 148)
    #expect(ImageBlockLayout(image: image, availableWidth: 180).imageSize.width == 180)
    #expect(image.displayWidth == 240)
    image.pixelWidth = 100; image.pixelHeight = 2000
    let tall = ImageBlockLayout(image: image, availableWidth: 360)
    #expect(tall.imageSize.height == 600 && tall.imageSize.width == 30)
    image.displayWidth = .infinity
    #expect(!image.isValid)
    image.displayWidth = -1; #expect(!image.isValid)
    let old = Data("{\"id\":\"\(UUID())\",\"name\":\"old\",\"pixelWidth\":100,\"pixelHeight\":50}".utf8)
    let decoded = try JSONDecoder().decode(NoteImage.self, from: old)
    #expect(decoded.caption == nil && decoded.displayWidth == nil && decoded.isValid)
}

@Test @MainActor func imageResizePreviewsWithoutSavingAndCommitsOneNativeUndo() throws {
    let asset = NoteImage(id: UUID(), name: "image", pixelWidth: 1200, pixelHeight: 600)
    let block = NoteBlock(kind: .image, image: asset)
    let original = NoteContent(blocks: [NoteBlock(text: "前文"), block, NoteBlock(text: "后文")])
    let (editor, window, delegate) = imageEditor(original); defer { window.close() }
    var changes = 0; editor.onContentChange = { _ in changes += 1 }
    editor.setSelectedRange(NSRange(location: 1, length: 0))
    let initial = try #require(editor.imageFrame(blockID: block.id))
    #expect(editor.beginImageResize(blockID: block.id, side: 1))
    for delta in [-10.0, -20, -30] { editor.previewImageResize(delta: delta) }
    #expect(editor.content == original && changes == 0 && !delegate.history.canUndo)
    let preview = try #require(editor.imageFrame(blockID: block.id))
    #expect(abs(preview.width - (initial.width - 60)) < 1)
    #expect(abs(preview.midX - initial.midX) < 1)
    delegate.history.beginUndoGrouping(); editor.endImageResize(cancelled: false); delegate.history.endUndoGrouping()
    #expect(changes == 1 && editor.content.blocks[1].image?.displayWidth == initial.width - 60)
    #expect(editor.selectedRange() == NSRange(location: 1, length: 0))
    delegate.history.undo(); #expect(editor.content == original)
    #expect(editor.beginImageResize(blockID: block.id, side: -1))
    editor.previewImageResize(delta: 35); editor.endImageResize(cancelled: true)
    #expect(editor.content == original)
    #expect(abs(try #require(editor.imageFrame(blockID: block.id)).width - initial.width) < 1)
    editor.isEditable = false; #expect(!editor.beginImageResize(blockID: block.id, side: 1))
}

@Test @MainActor func imageCaptionEditsStayAttachedAndCancelKeepsOriginal() throws {
    let image = NoteImage(id: UUID(), name: "image", pixelWidth: 600, pixelHeight: 300)
    let block = NoteBlock(kind: .image, image: image)
    let original = NoteContent(blocks: [block, NoteBlock(text: "正文")])
    let (editor, window, delegate) = imageEditor(original); defer { window.close() }
    editor.beginImageCaption(blockID: block.id)
    let controls = try #require(editor.imageControls)
    #expect(controls.editingCaption && !controls.captionField.isHidden)
    #expect(editor.content == original)
    let editingHeight = try #require(editor.imageFrame(blockID: block.id)).height
    editor.updateColors(.brown)
    #expect(try #require(editor.imageFrame(blockID: block.id)).height == editingHeight)
    #expect(controls.editingCaption && editor.content == original)
    controls.captionField.stringValue = "中文标题 🌿"
    delegate.history.beginUndoGrouping(); editor.endImageCaption(cancelled: false); delegate.history.endUndoGrouping()
    #expect(editor.content.blocks[0].image?.caption == "中文标题 🌿")
    #expect(editor.content.blocks[1] == original.blocks[1])
    let changed = editor.content
    #expect(BlockTextCodec.read(editor.attributedString(), typing: editor.typingAttributes).map(\.block) == changed.blocks)
    delegate.history.undo(); #expect(editor.content == original)
    delegate.history.redo(); #expect(editor.content == changed)
    controls.isPresentingMenu = true
    editor.beginImageCaption(blockID: block.id)
    #expect(controls.captionField.frame.width > 0 && controls.captionField.frame.minY > 0)
    controls.isPresentingMenu = false
    controls.captionField.stringValue = "取消"
    editor.endImageCaption(cancelled: true); #expect(editor.content == changed)
    delegate.history.beginUndoGrouping(); #expect(editor.performBlockAction(.duplicate, blockID: block.id)); delegate.history.endUndoGrouping()
    #expect(editor.content.blocks[1].image == changed.blocks[0].image)
    delegate.history.undo(); #expect(editor.content == changed)
}

@Test @MainActor func imageHoverControlsUseRealAttachmentFrameAndPassThrough() throws {
    let block = NoteBlock(kind: .image, image: NoteImage(id: UUID(), name: "image", pixelWidth: 600, pixelHeight: 300, displayWidth: 220, caption: "标题"))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = NoteFile(url: directory.appendingPathComponent("note.json"))
    try FileManager.default.createDirectory(at: file.assetsURL, withIntermediateDirectories: true)
    let source = NSImage(size: NSSize(width: 600, height: 300), flipped: true) { rect in
        NSColor(calibratedRed: 0.83, green: 0.89, blue: 0.94, alpha: 1).setFill(); rect.fill()
        "Foldpin · Image".draw(at: NSPoint(x: 40, y: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 32, weight: .medium), .foregroundColor: NSColor.darkGray])
        NSColor.white.withAlphaComponent(0.5).setFill()
        for i in 0..<3 { NSRect(x: 40, y: 140 + i * 32, width: 360 - i * 60, height: 14).fill() }
        return true
    }
    let tiff = try #require(source.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: tiff))
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: file.imageURL(block.image!.id))
    let (editor, window, delegate) = imageEditor(NoteContent(blocks: [block, NoteBlock(text: "after")]), file: file)
    defer { window.close(); _ = delegate }
    let rect = try #require(editor.imageFrame(blockID: block.id))
    editor.updateImageControls(at: NSPoint(x: rect.midX, y: rect.minY + 50))
    let controls = try #require(editor.imageControls)
    #expect(!controls.isHidden && !controls.leftGrip.isHidden && !controls.rightGrip.isHidden)
    let left = controls.convert(controls.leftGrip.frame, to: editor)
    let right = controls.convert(controls.rightGrip.frame, to: editor)
    #expect(abs(left.minX - rect.minX) < 1 && abs(right.maxX - rect.maxX) < 1)
    let center = controls.superview!.convert(NSPoint(x: rect.midX, y: rect.minY + 80), from: editor)
    #expect(controls.hitTest(center) == nil)
    if let folder = ProcessInfo.processInfo.environment["FOLDPIN_IMAGE_PREVIEW_DIRECTORY"], let root = window.contentView {
        root.layoutSubtreeIfNeeded()
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent("image-controls.png"))
    }
    editor.updateImageControls(at: NSPoint(x: 0, y: 400)); #expect(controls.isHidden)
}

@Test @MainActor func imageCaptionSizePersistAndRichCopyKeepsOriginalPixels() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = NoteFile(url: directory.appendingPathComponent("note.json"))
    try FileManager.default.createDirectory(at: file.assetsURL, withIntermediateDirectories: true)
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 480, bitsPerPixel: 32))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let image = NoteImage(id: UUID(), name: "source.png", pixelWidth: 120, pixelHeight: 60, displayWidth: 80, caption: "图片 <标题> 🌿")
    for original in [true, false] { try png.write(to: file.imageURL(image.id, original: original)) }
    var document = NoteDocument(); document.content = NoteContent(blocks: [NoteBlock(kind: .image, image: image), NoteBlock(text: "正文")])
    try file.save(document); #expect(try file.load() == document)
    let board = NSPasteboard(name: .init("Foldpin-image-layout-test-\(UUID())")); defer { board.releaseGlobally() }
    try NoteClipboard.copy(document.content, file: file, to: board)
    let html = try #require(board.string(forType: .html))
    #expect(html.contains("<figcaption>图片 &lt;标题&gt; 🌿</figcaption>") && html.contains("width=\"80\""))
    let rich = try NSAttributedString(data: #require(board.data(forType: .rtfd)), options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
    #expect(rich.string.contains("图片 <标题> 🌿") && rich.string.contains("正文"))
    let attachment = try #require(rich.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
    #expect(attachment.fileWrapper?.regularFileContents == png)
    #expect(try Data(contentsOf: file.imageURL(image.id, original: true)) == png)
    #expect(board.string(forType: .string)?.contains("图片 <标题> 🌿") == true)
    let payload = try JSONDecoder().decode(NoteContent.self, from: #require(board.data(forType: NoteClipboard.blocksType)))
    #expect(payload == document.content)
}
