import AppKit
import Testing
@testable import FoldpinCore

@Test @MainActor func mediaExportPreservesOriginalImageBytesAndDetectsFormat() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32,
        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let original = try #require(bitmap.representation(using: .jpeg, properties: [:]))
    let file = NoteFile(url: directory.appendingPathComponent("note.json"), assetDirectory: directory)
    let image = NoteImage(id: UUID(), name: "假后缀.png", pixelWidth: 64, pixelHeight: 32, displayWidth: 40, caption: "不要烧进图片")
    try original.write(to: file.imageURL(image.id, original: true))
    try Data("preview must not be exported".utf8).write(to: file.imageURL(image.id))
    let export = try MediaExport.image(at: file.imageURL(image.id, original: true), name: image.name, fallback: "Image")
    #expect(export.contentType == .jpeg)
    #expect((export.filename as NSString).deletingPathExtension == "假后缀")
    let destination = directory.appendingPathComponent(export.filename)
    try export.write(to: destination)
    #expect(try Data(contentsOf: destination) == original)
    let exported = try Data(contentsOf: destination)
    #expect(NSBitmapImageRep(data: exported)?.pixelsWide == 64)
}

@Test func mediaExportAudioPreservesBytesAndCleansFilename() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // Copy behavior does not decode or transcode audio; no microphone or playback is needed.
    let bytes = Data((0..<4096).map { UInt8($0 % 256) })
    let source = directory.appendingPathComponent("source.m4a")
    try bytes.write(to: source)
    var audio = NoteAudio(name: "会议/上午:\n录音.m4a", fileExtension: "m4a", duration: 3)
    let export = try MediaExport.audio(at: source, audio: audio, fallback: "Audio")
    #expect(export.filename == "会议-上午--录音.m4a")
    let destination = directory.appendingPathComponent(export.filename)
    try export.write(to: destination)
    #expect(try Data(contentsOf: destination) == bytes)
    #expect(try Data(contentsOf: source) == bytes)
    audio.isDraft = true
    #expect(throws: (any Error).self) { try MediaExport.audio(at: source, audio: audio, fallback: "Audio") }
}

@Test func mediaExportMissingSourcePreservesExistingDestination() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("original.m4a")
    let destination = directory.appendingPathComponent("saved.m4a")
    try Data("asset".utf8).write(to: source)
    let previous = Data("previous exported file".utf8)
    try previous.write(to: destination)
    let export = try MediaExport.audio(at: source, audio: NoteAudio(name: "voice", fileExtension: "m4a", duration: 1), fallback: "Audio")
    try FileManager.default.removeItem(at: source)
    #expect(throws: (any Error).self) { try export.write(to: destination) }
    #expect(try Data(contentsOf: destination) == previous)
    #expect(throws: (any Error).self) { try MediaExport.image(at: source, name: "lost", fallback: "Image") }
}

@Test @MainActor func mediaExportMenuTargetsImageAndAudioWithoutChangingSelection() throws {
    _ = NSApplication.shared
    let image = NoteBlock(kind: .image, image: NoteImage(id: UUID(), name: "photo", pixelWidth: 100, pixelHeight: 50))
    let audio = NoteBlock(kind: .audio, audio: NoteAudio(name: "voice", fileExtension: "m4a", duration: 1))
    let text = NoteBlock(text: "正文")
    let content = NoteContent(blocks: [text, image, audio])
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.configure(content: content)
    editor.setSelectedRange(NSRange(location: 1, length: 0))
    for block in [image, audio] {
        let menu = try #require(editor.makeBlockActionMenu(blockID: block.id))
        let commands = menu.items.compactMap { $0.representedObject as? BlockMenuCommand }
        let command = try #require(commands.first { $0.action == .exportMedia })
        #expect(command.blockID == block.id)
    }
    let menu = try #require(editor.makeBlockActionMenu(blockID: text.id))
    #expect(!menu.items.contains { ($0.representedObject as? BlockMenuCommand)?.action == .exportMedia })
    #expect(editor.content == content && editor.selectedRange() == NSRange(location: 1, length: 0))
}
