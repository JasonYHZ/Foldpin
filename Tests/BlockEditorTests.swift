import AppKit
import Testing
@testable import FoldpinCore

@Test func v1MigrationPreservesBytesAndBacksUpBeforeFirstSave() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = NoteFile(url: directory.appendingPathComponent("note.json"))
    let id = UUID()
    let text = "# literal title\r\n\n  中文 e\u{301} 👨‍👩‍👧‍👦\t\n"
    let original = try JSONSerialization.data(withJSONObject: [
        "version": 1, "id": id.uuidString, "text": text,
        "isPinned": true, "isShelved": true, "isCollapsed": true,
        "modifiedAt": 12, "frame": ["x": -300, "y": 100, "width": 360, "height": 400]
    ], options: .prettyPrinted)
    try original.write(to: file.url)
    var migrated = try file.load()
    #expect(migrated.version == 2)
    #expect(migrated.text == text)
    #expect(migrated.id == id && migrated.isPinned && migrated.isShelved && migrated.isCollapsed)
    #expect(migrated.content.blocks.allSatisfy { $0.kind == .paragraph })
    #expect(try Data(contentsOf: file.url) == original)
    migrated.content.blocks[0].kind = .heading
    try file.save(migrated)
    let backups = try FileManager.default.contentsOfDirectory(at: file.backupsURL, includingPropertiesForKeys: nil)
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: #require(backups.first)) == original)
    #expect(try file.load() == migrated)
    try file.save(migrated)
    #expect(try FileManager.default.contentsOfDirectory(atPath: file.backupsURL.path).count == 1)
}

@Test func failedMigrationBackupNeverReplacesV1() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = NoteFile(url: directory.appendingPathComponent("note.json"))
    let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "id": UUID().uuidString, "text": "safe",
                                                           "isPinned": false, "isShelved": false, "modifiedAt": 0])
    try bytes.write(to: file.url)
    try Data("blocked backup directory".utf8).write(to: file.backupsURL)
    #expect(throws: (any Error).self) { try file.save(file.load()) }
    #expect(try Data(contentsOf: file.url) == bytes)
}

@Test func blockValidationRejectsDuplicateIDsBadMarksAndMissingImages() throws {
    let block = NoteBlock(text: "中文")
    #expect(throws: NoteFileError.self) { try NoteContent(blocks: [block, block]).validate() }
    var invalid = block
    invalid.marks = [NoteTextMark(location: 1, length: Int.max, bold: true)]
    #expect(throws: NoteFileError.self) { try NoteContent(blocks: [invalid]).validate() }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = NoteFile(url: directory.appendingPathComponent("note.json"))
    var document = NoteDocument(); document.text = "existing"
    try file.save(document)
    let original = try Data(contentsOf: file.url)
    document.content.blocks.append(NoteBlock(kind: .image, image: NoteImage(id: UUID(), name: "missing.png", pixelWidth: 20, pixelHeight: 20)))
    #expect(throws: NoteFileError.self) { try file.save(document) }
    #expect(try Data(contentsOf: file.url) == original)
}

@Test @MainActor func nativeAttributedRoundTripPreservesBlocksCodeAndMarks() throws {
    let blocks = [
        NoteBlock(kind: .heading, text: "标题"),
        NoteBlock(kind: .task, text: "中文 🌿", marks: [NoteTextMark(location: 0, length: 2, bold: true)], isChecked: true),
        NoteBlock(kind: .code, text: "let x = 1\n\n  print(x)\n", language: .swift),
        NoteBlock(kind: .image, image: NoteImage(id: UUID(), name: "image.png", pixelWidth: 30, pixelHeight: 20)),
        NoteBlock()
    ]
    let content = NoteContent(blocks: blocks)
    let attributed = BlockTextCodec.render(content, color: .labelColor, width: 280, image: { _ in nil })
    let read = NoteContent(blocks: BlockTextCodec.read(attributed, typing: BlockTextCodec.metadata(blocks.last!)).map(\.block))
    #expect(read == content)
    try read.validate()
}

@Test @MainActor func literalPastedNewlinesReceiveDistinctBlockIDs() throws {
    let original = NoteBlock(text: "")
    let text = NSAttributedString(string: "第一行\n第二行\n", attributes: BlockTextCodec.metadata(original))
    let blocks = BlockTextCodec.read(text, typing: BlockTextCodec.metadata(original)).map(\.block)
    let content = NoteContent(blocks: blocks)
    #expect(content.plainText == text.string)
    #expect(blocks.count == 3)
    try content.validate()
}

@Test @MainActor func trailingEmptyBlockKeepsItsIdentityWhenCaretIsElsewhere() {
    let blocks = [NoteBlock(kind: .heading, text: "Title"), NoteBlock()]
    let content = NoteContent(blocks: blocks)
    let value = BlockTextCodec.render(content, color: .labelColor, width: 280, image: { _ in nil })
    let decoded = NoteContent(blocks: BlockTextCodec.read(value, typing: BlockTextCodec.metadata(blocks[0])).map(\.block))
    #expect(decoded == content)
}

@Test @MainActor func convertingMultilineCodeToParagraphsKeepsTextAndValidBlockIndexes() throws {
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.isRichText = true
    editor.configure(content: NoteContent(blocks: [NoteBlock(kind: .code, text: "one\ntwo\nthree", language: .swift)]))
    let item = NSMenuItem()
    item.representedObject = NoteBlockKind.paragraph.rawValue
    editor.perform(NSSelectorFromString("selectKind:"), with: item)
    #expect(editor.content.blocks.map(\.text) == ["one", "two", "three"])
    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    editor.insertNewline(nil)
    #expect(editor.content.blocks.map(\.text) == ["one", "two", "three", ""])
    try editor.content.validate()
}

@MainActor private final class EditorUndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}

@Test @MainActor func nativeSplitAndUndoRestoreContentAndFormatting() throws {
    let delegate = EditorUndoDelegate()
    delegate.history.groupsByEvent = false
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.delegate = delegate
    editor.isRichText = true; editor.allowsUndo = true
    let original = NoteContent(blocks: [NoteBlock(kind: .heading, text: "中文标题")])
    editor.configure(content: original)
    editor.setSelectedRange(NSRange(location: 2, length: 0))
    delegate.history.beginUndoGrouping()
    editor.insertNewline(nil)
    delegate.history.endUndoGrouping()
    #expect(editor.content.blocks.map(\.text) == ["中文", "标题"])
    #expect(editor.content.blocks.map(\.kind) == [.heading, .paragraph])
    #expect(editor.selectedRange().location == 3)
    #expect(delegate.history.canUndo)
    delegate.history.undo()
    #expect(editor.string == "中文标题")
    #expect(editor.content == original)
    delegate.history.redo()
    #expect(editor.content.blocks.map(\.text) == ["中文", "标题"])
}

@Test @MainActor func typingAndCodeNewlineUseNativeTextKit2() throws {
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.isRichText = true
    editor.configure(content: NoteContent(blocks: [NoteBlock(kind: .code, text: "let a = 1", language: .swift)]))
    #expect(editor.textLayoutManager != nil)
    editor.insertNewline(nil)
    editor.insertText("  中文", replacementRange: editor.selectedRange())
    #expect(editor.content.blocks.count == 1)
    #expect(editor.content.blocks.first?.text == "let a = 1\n  中文")
    #expect(editor.content.blocks.first?.kind == .code)
}

@Test @MainActor func imageImportPersistsOriginalAndPreviewBeforeDocument() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
    let file = NoteFile(url: directory.appendingPathComponent("note.json"))
    let prepared = try NoteImageImporter.prepare(data: bytes, name: "sample.png", directory: file.assetsURL)
    #expect(try Data(contentsOf: file.imageURL(prepared.image.id, original: true)) == bytes)
    #expect(NSImage(contentsOf: file.imageURL(prepared.image.id)) != nil)
    var document = NoteDocument()
    document.content = NoteContent(blocks: [NoteBlock(kind: .image, image: prepared.image), NoteBlock(text: "图后正文")])
    try file.save(document)
    #expect(try file.load() == document)
    document.content.blocks.removeFirst()
    try file.save(document)
    #expect(FileManager.default.fileExists(atPath: file.imageURL(prepared.image.id).path))
    #expect(throws: (any Error).self) {
        try NoteImageImporter.prepare(data: Data("not an image".utf8), name: "fake.png", directory: file.assetsURL)
    }
}

@Test @MainActor func imageBoundaryBackspaceSelectsThenDeletesWithoutLosingFollowingText() throws {
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.isRichText = true
    let original = NoteContent(blocks: [NoteBlock(text: "A"),
        NoteBlock(kind: .image, image: NoteImage(id: UUID(), name: "sample.png", pixelWidth: 40, pixelHeight: 20)),
        NoteBlock(text: "B")])
    editor.configure(content: original)
    editor.setSelectedRange(NSRange(location: 4, length: 0))
    editor.deleteBackward(nil)
    #expect(editor.selectedRange() == NSRange(location: 2, length: 1))
    #expect(editor.content == original)
    editor.deleteBackward(nil)
    #expect(editor.content.blocks.contains { $0.text == "B" })
    #expect(!editor.content.blocks.contains { $0.image != nil })
    try editor.content.validate()
}

@Test @MainActor func slashSuggestionsAllowBackspaceAndKeepDeletionUndoable() {
    let delegate = EditorUndoDelegate()
    delegate.history.groupsByEvent = false
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.isRichText = true; editor.allowsUndo = true; editor.delegate = delegate
    editor.configure(content: NoteContent())
    delegate.history.beginUndoGrouping()
    editor.insertText("/", replacementRange: editor.selectedRange())
    delegate.history.endUndoGrouping()
    #expect(editor.hasSlashSuggestions)
    delegate.history.beginUndoGrouping()
    editor.deleteBackward(nil)
    delegate.history.endUndoGrouping()
    #expect(editor.string.isEmpty)
    #expect(editor.content.plainText.isEmpty)
    #expect(!editor.hasSlashSuggestions)
    delegate.history.undo()
    #expect(editor.string == "/")
    #expect(editor.content.plainText == "/")
}

@Test @MainActor func slashSuggestionsAllowTypingAndEscapeDoesNotShelveNote() {
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.isRichText = true
    editor.configure(content: NoteContent())
    var shelved = false
    editor.onEscape = { shelved = true }
    editor.insertText("/", replacementRange: editor.selectedRange())
    #expect(editor.hasSlashSuggestions)
    editor.cancelOperation(nil)
    #expect(!editor.hasSlashSuggestions)
    #expect(!shelved)
    #expect(editor.string == "/")
    editor.deleteBackward(nil)
    editor.insertText("/", replacementRange: editor.selectedRange())
    #expect(editor.hasSlashSuggestions)
    editor.insertText("路径", replacementRange: editor.selectedRange())
    #expect(editor.content.plainText == "/路径")
    #expect(!editor.hasSlashSuggestions)
}

@Test @MainActor func slashSuggestionsArrowAndReturnConvertBlockWithoutExtraNewline() {
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.isRichText = true
    editor.configure(content: NoteContent())
    editor.insertText("/", replacementRange: editor.selectedRange())
    #expect(editor.hasSlashSuggestions)
    editor.moveDown(nil)
    editor.insertNewline(nil)
    #expect(!editor.hasSlashSuggestions)
    #expect(editor.content.blocks.count == 1)
    #expect(editor.content.blocks.first?.kind == .heading)
    #expect(editor.string.isEmpty)
    editor.insertText("标题", replacementRange: editor.selectedRange())
    #expect(editor.content.blocks.first?.text == "标题")
    #expect(editor.content.blocks.first?.kind == .heading)
}
