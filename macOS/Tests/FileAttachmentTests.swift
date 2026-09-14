import AppKit
import Testing
@testable import FoldpinCore

@Test func fileAttachmentsKeepBytesAndRollbackFailedBatch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("report.pdf")
    let bytes = Data([0, 1, 2, 3, 255])
    try bytes.write(to: source)
    let assets = root.appendingPathComponent("assets")
    let values = try NoteAttachmentImporter.prepare(urls: [source, source], directory: assets)
    #expect(values.count == 2 && values[0].id != values[1].id)
    for value in values {
        #expect(value.name == "report.pdf" && value.byteCount == bytes.count)
        #expect(try Data(contentsOf: value.url(in: assets)) == bytes)
    }
    let before = try FileManager.default.contentsOfDirectory(atPath: assets.path).sorted()
    #expect(throws: (any Error).self) { try NoteAttachmentImporter.prepare(urls: [source, root], directory: assets) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: assets.path).sorted() == before)
    let link = root.appendingPathComponent("link.pdf")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    #expect(throws: (any Error).self) { try NoteAttachmentImporter.prepare(urls: [link], directory: assets) }
    let large = root.appendingPathComponent("large.bin")
    FileManager.default.createFile(atPath: large.path, contents: nil)
    let handle = try FileHandle(forWritingTo: large)
    try handle.truncate(atOffset: UInt64(NoteAttachmentImporter.byteLimit + 1)); try handle.close()
    #expect(throws: (any Error).self) { try NoteAttachmentImporter.prepare(urls: [large], directory: assets) }
    try FileManager.default.removeItem(at: source)
    #expect(try Data(contentsOf: values[0].url(in: assets)) == bytes)
    for name in ["../x", "a/b", "a\\b", "", ".", "..", "bad\nname"] {
        #expect(!NoteAttachment(name: name, byteCount: 1).isValid)
    }
}

@Test @MainActor func fileAttachmentRoundTripClipboardUndoAndMissingFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("spec.txt")
    let bytes = Data("attachment original".utf8)
    try bytes.write(to: source)
    let file = NoteFile(url: root.appendingPathComponent("note.json"))
    let attachment = try #require(NoteAttachmentImporter.prepare(urls: [source], directory: file.assetsURL.appendingPathComponent("files")).first)
    let block = NoteBlock(kind: .file, attachment: attachment)
    var document = NoteDocument(); document.content = NoteContent(blocks: [block, NoteBlock(text: "after")])
    try file.save(document)
    #expect(try file.load() == document)
    #expect(!document.content.isBlankForClosing)
    #expect(throws: NoteFileError.self) { try NoteContent(blocks: [NoteBlock(kind: .file)]).validate() }
    #expect(throws: NoteFileError.self) { try NoteContent(blocks: [NoteBlock(attachment: attachment)]).validate() }
    let rendered = BlockTextCodec.render(document.content, color: .black, width: 320, image: { _ in nil })
    #expect(BlockTextCodec.read(rendered, typing: [:]).map(\.block) == document.content.blocks)
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.frame = NSRect(x: 0, y: 0, width: 360, height: 300)
    editor.file = file; editor.isEditable = true; editor.allowsUndo = true
    editor.sessionUndoManager = UndoManager()
    editor.isRichText = true
    editor.configure(content: NoteContent())
    editor.sessionUndoManager?.groupsByEvent = false
    let original = editor.content
    let undo = try #require(editor.undoManager)
    undo.beginUndoGrouping()
    #expect(editor.insertAttachments([attachment], source: original.blocks[0]))
    undo.endUndoGrouping()
    #expect(editor.content.blocks.first?.attachment == attachment)
    undo.undo(); #expect(editor.content == original)
    undo.redo(); #expect(editor.content.blocks.first?.attachment == attachment)
    #expect(!editor.insertAttachments([attachment], source: NoteBlock(text: "stale")))
    let board = NSPasteboard(name: .init(UUID().uuidString))
    defer { board.releaseGlobally() }
    try NoteClipboard.copy(document.content, file: file, to: board)
    let encoded = try #require(board.data(forType: NoteClipboard.blocksType))
    #expect(try JSONDecoder().decode(NoteContent.self, from: encoded) == document.content)
    editor.configure(content: NoteContent())
    undo.beginUndoGrouping()
    #expect(editor.insertPastedBlocks(document.content))
    undo.endUndoGrouping()
    let pasted = try #require(editor.content.blocks.first(where: { $0.attachment != nil }))
    #expect(pasted.id != block.id && pasted.attachment == attachment)
    let rtfd = try #require(board.data(forType: .rtfd))
    let portable = try NSAttributedString(data: rtfd, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
    let copied = try #require(portable.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
    #expect(copied.fileWrapper?.regularFileContents == bytes)
    #expect(board.string(forType: .html)?.contains(bytes.base64EncodedString()) == true)
    let export = try MediaExport.attachment(at: file.attachmentURL(attachment), attachment: attachment)
    #expect(export.filename == "spec.txt")
    let exported = root.appendingPathComponent("exported.txt")
    try export.write(to: exported); #expect(try Data(contentsOf: exported) == bytes)
    let previous = try Data(contentsOf: file.url)
    try FileManager.default.removeItem(at: file.attachmentURL(attachment))
    #expect(throws: (any Error).self) { try file.save(document) }
    #expect(try Data(contentsOf: file.url) == previous)
    board.clearContents(); board.setString("keep clipboard", forType: .string)
    #expect(throws: (any Error).self) { try NoteClipboard.copy(document.content, file: file, to: board) }
    #expect(board.string(forType: .string) == "keep clipboard")
}
