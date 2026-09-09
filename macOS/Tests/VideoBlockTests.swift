import AppKit
import AVFoundation
import Testing
@testable import FoldpinCore

private func videoFixture(_ directory: URL) async throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("测试视频.mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 160, AVVideoHeightKey: 90])
    input.transform = CGAffineTransform(rotationAngle: .pi / 2)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90,
            kCVPixelBufferCGImageCompatibilityKey as String: true])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<10 {
        var wait = 0
        while !input.isReadyForMoreMediaData && wait < 500 {
            try await Task.sleep(for: .milliseconds(10)); wait += 1
        }
        guard input.isReadyForMoreMediaData else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 160, 90, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let data = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) {
            let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
            for y in 0..<90 { for x in 0..<160 {
                let i = y * rowBytes + x * 4
                data[i] = 180; data[i + 1] = UInt8(60 + x); data[i + 2] = UInt8(50 + y); data[i + 3] = 255
            } }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)) else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    return url
}

@Test func videoImportPreservesSourceOrientationPosterAndExport() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try await videoFixture(directory)
    let bytes = try Data(contentsOf: source)
    let file = NoteFile(url: directory.appendingPathComponent("note.json"))
    let video = try await NoteVideoImporter.prepare(url: source, directory: file.assetsURL)
    #expect(video.isValid && video.pixelWidth.rounded() == 90 && video.pixelHeight.rounded() == 160)
    #expect(video.duration > 0 && video.duration < 2)
    #expect(try Data(contentsOf: file.videoURL(video)) == bytes)
    #expect(try Data(contentsOf: source) == bytes)
    #expect(FileManager.default.fileExists(atPath: file.videoPosterURL(video).path))
    let export = try MediaExport.video(at: file.videoURL(video), video: video, fallback: "Video")
    let output = directory.appendingPathComponent("export.mov")
    try export.write(to: output)
    #expect(try Data(contentsOf: output) == bytes && export.filename == "测试视频.mov")
}

@Test func videoInvalidImportCleansAssetsAndMetadataRejectsPaths() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("bad.mp4")
    let bytes = Data("not a video".utf8)
    try bytes.write(to: source)
    let assets = directory.appendingPathComponent("assets")
    await #expect(throws: (any Error).self) { try await NoteVideoImporter.prepare(url: source, directory: assets) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: assets.path).isEmpty)
    #expect(try Data(contentsOf: source) == bytes)
    var video = NoteVideo(name: "film", fileExtension: "../mov", duration: 1, pixelWidth: 100, pixelHeight: 100)
    #expect(!video.isValid)
    video.fileExtension = "mov"; video.duration = .infinity; #expect(!video.isValid)
    video.duration = 1; video.pixelWidth = 0; #expect(!video.isValid)
}

@Test func videoPersistsAndMissingAssetDoesNotOverwritePreviousNote() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = NoteFile(url: directory.appendingPathComponent("note.json"))
    let video = NoteVideo(name: "film", fileExtension: "mp4", duration: 2, pixelWidth: 640, pixelHeight: 360)
    try FileManager.default.createDirectory(at: file.assetsURL, withIntermediateDirectories: true)
    try Data("asset".utf8).write(to: file.videoURL(video))
    var document = NoteDocument()
    document.content = NoteContent(blocks: [NoteBlock(kind: .video, video: video), NoteBlock(text: "保留正文")])
    try file.save(document)
    #expect(try file.load().content == document.content)
    let previous = try Data(contentsOf: file.url)
    try FileManager.default.removeItem(at: file.videoURL(video))
    document.content.blocks[1].text = "change"
    #expect(throws: (any Error).self) { try file.save(document) }
    #expect(try Data(contentsOf: file.url) == previous)
    let old = try JSONDecoder().decode(NoteBlock.self, from: JSONEncoder().encode(NoteBlock(text: "legacy")))
    #expect(old.video == nil)
}

@MainActor private final class VideoUndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}

@MainActor private func videoEditor(_ file: NoteFile) -> (PaperTextView, NSWindow, VideoUndoDelegate) {
    _ = NSApplication.shared
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.frame = NSRect(x: 0, y: 0, width: 420, height: 600)
    editor.textContainerInset = NSSize(width: 32, height: 8)
    editor.textContainer?.size = NSSize(width: 356, height: CGFloat.greatestFiniteMagnitude)
    editor.textContainer?.widthTracksTextView = true; editor.textContainer?.lineFragmentPadding = 0
    editor.file = file; editor.isRichText = true; editor.configure(content: NoteContent())
    let delegate = VideoUndoDelegate(); delegate.history.groupsByEvent = false
    editor.delegate = delegate; editor.allowsUndo = true
    let window = NSWindow(contentRect: editor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame: editor.frame); scroll.documentView = editor; window.contentView = scroll
    return (editor, window, delegate)
}

@Test @MainActor func videoInsertionUndoAndNativePlayerLifecycle() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = try await videoFixture(directory)
    let file = NoteFile(url: directory.appendingPathComponent("note.json"))
    let video = try await NoteVideoImporter.prepare(url: sourceURL, directory: file.assetsURL)
    let (editor, window, delegate) = videoEditor(file); defer { window.close() }
    let original = editor.content, source = original.blocks[0]
    delegate.history.beginUndoGrouping()
    let id = try #require(editor.insertVideo(video, source: source))
    delegate.history.endUndoGrouping()
    let inserted = editor.content
    #expect(BlockTextCodec.read(editor.attributedString(), typing: editor.typingAttributes).map(\.block) == inserted.blocks)
    #expect(inserted.blocks[0].video == video && inserted.blocks.last?.kind == .paragraph)
    editor.textLayoutManager?.ensureLayout(for: editor.textLayoutManager!.textContentManager!.documentRange)
    editor.layoutSubtreeIfNeeded(); editor.synchronizeVideoViews()
    let view = try #require(editor.subviews.compactMap { $0 as? VideoBlockView }.first)
    view.layoutSubtreeIfNeeded()
    #expect(view.frame.width > 0 && view.frame.height > 0 && view.model.player == nil)
    #expect(view.playerView.isHidden)
    let preview = URL(fileURLWithPath: "/private/tmp/Foldpin-VideoPreview")
    try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let composite = NSImage(size: view.bounds.size, flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            bitmap.draw(in: rect)
            return true
        }
        let tiff = try #require(composite.tiffRepresentation)
        let flattened = try #require(NSBitmapImageRep(data: tiff))
        try flattened.representation(using: .png, properties: [:])?.write(to: preview.appendingPathComponent("video-block.png"))
    }
    let model = view.model
    let play = try #require(view.subviews.compactMap { $0 as? NSButton }.first { $0.action == NSSelectorFromString("playVideo") })
    play.performClick(nil)
    let player = try #require(model.player)
    #expect(view.playerView.player === player && !view.playerView.isHidden)
    for _ in 0..<100 {
        if player.currentTime().seconds > 0.1 { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(player.currentTime().seconds > 0.1)
    #expect(editor.prepareAudioForHiding())
    #expect(model.player == nil && VideoBlockModel.playing == nil)
    delegate.history.undo(); #expect(editor.content == original)
    delegate.history.redo(); #expect(editor.content == inserted)
    delegate.history.beginUndoGrouping(); #expect(editor.performBlockAction(.duplicate, blockID: id)); delegate.history.endUndoGrouping()
    #expect(editor.content.blocks.filter { $0.video?.id == video.id }.count == 2)
    delegate.history.undo()
    delegate.history.beginUndoGrouping(); #expect(editor.performBlockAction(.delete, blockID: id)); delegate.history.endUndoGrouping()
    #expect(!editor.content.blocks.contains { $0.video != nil })
    #expect(!editor.subviews.contains { $0 is VideoBlockView })
    delegate.history.undo(); #expect(editor.content == inserted)
    #expect(FileManager.default.fileExists(atPath: file.videoURL(video).path))
    #expect(editor.insertVideo(video, source: source) == nil)
    let menu = try #require(editor.makeBlockActionMenu(blockID: id))
    #expect(menu.items.contains { ($0.representedObject as? BlockMenuCommand)?.action == .exportMedia })
}

@Test @MainActor func videoClipboardEmbedsOriginalAndProtectsClipboardOnFailure() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = NoteFile(url: directory.appendingPathComponent("note.json"))
    try FileManager.default.createDirectory(at: file.assetsURL, withIntermediateDirectories: true)
    let video = NoteVideo(name: "<影片>", fileExtension: "mp4", duration: 2, pixelWidth: 640, pixelHeight: 360)
    let bytes = Data("original video payload".utf8)
    try bytes.write(to: file.videoURL(video))
    let content = NoteContent(blocks: [NoteBlock(kind: .video, video: video)])
    let board = NSPasteboard(name: .init("Foldpin-video-tests-" + UUID().uuidString))
    defer { board.releaseGlobally() }
    try NoteClipboard.copy(content, file: file, to: board)
    let html = try #require(board.string(forType: .html))
    #expect(html.contains("<video controls") && html.contains("&lt;影片&gt;") && html.contains(bytes.base64EncodedString()))
    let rtfd = try #require(board.data(forType: .rtfd))
    let rich = try NSAttributedString(data: rtfd, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
    let attachment = try #require(rich.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
    #expect(attachment.fileWrapper?.regularFileContents == bytes)
    #expect(try JSONDecoder().decode(NoteContent.self, from: #require(board.data(forType: NoteClipboard.blocksType))) == content)
    let previous = board.changeCount
    try FileManager.default.removeItem(at: file.videoURL(video))
    #expect(throws: (any Error).self) { try NoteClipboard.copy(content, file: file, to: board) }
    #expect(board.changeCount == previous)
    // A sparse file exercises the limit without allocating a large clipboard payload.
    FileManager.default.createFile(atPath: file.videoURL(video).path, contents: nil)
    let handle = try FileHandle(forWritingTo: file.videoURL(video))
    try handle.truncate(atOffset: 33 * 1024 * 1024); try handle.close()
    #expect(throws: (any Error).self) { try NoteClipboard.copy(content, file: file, to: board) }
    #expect(board.changeCount == previous)
}

@Test @MainActor func videoSurvivesNoteDeletionAndRestoreAfterReopening() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = NoteLibrary(directory: directory)
    let entry = try #require(library.entries.first)
    let video = NoteVideo(name: "保留视频", fileExtension: "mp4", duration: 2, pixelWidth: 640, pixelHeight: 360)
    let file = entry.store.file
    try FileManager.default.createDirectory(at: file.assetsURL, withIntermediateDirectories: true)
    let bytes = Data("persistent video asset".utf8)
    try bytes.write(to: file.videoURL(video))
    let content = NoteContent(blocks: [NoteBlock(kind: .video, video: video)])
    entry.store.edit(content)
    #expect(entry.store.flush())
    #expect(library.deleteNote(entry.id))
    let reopened = NoteLibrary(directory: directory)
    let restored = try #require(reopened.restoreNote(entry.id))
    #expect(restored.store.document.content == content)
    #expect(try Data(contentsOf: restored.store.file.videoURL(video)) == bytes)
}
