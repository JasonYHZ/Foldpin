import AppKit
import Testing
@testable import FoldpinCore

@Test @MainActor func textLinksMixedRelativeDestinationsDoNotDisableWebLinks() throws {
    let source = "This project follows [Semantic Versioning](https://semver.org/). Breaking changes are in [CHANGELOG](CHANGELOG.md)."
    let content = try #require(MarkdownPasteParser.parse(source))
    #expect(content.blocks.count == 1)
    let block = content.blocks[0]
    #expect(block.text == "This project follows Semantic Versioning. Breaking changes are in [CHANGELOG](CHANGELOG.md).")
    let link = try #require(block.marks.first(where: { $0.link != nil }))
    #expect((block.text as NSString).substring(with: NSRange(location: link.location, length: link.length)) == "Semantic Versioning")
    #expect(link.link == "https://semver.org/")
    let rendered = BlockTextCodec.render(content, color: .textColor, width: 440, image: { _ in nil })
    #expect(rendered.attribute(.link, at: link.location, effectiveRange: nil) as? URL == URL(string: "https://semver.org/"))
}

@Test func textLinksExplicitConversionKeepsStylesAndUnicodeAndRelativeText() throws {
    let text = "中文🌿 [版本说明](https://example.com/v_(1)) 和 [changelog](CHANGELOG.md) 后文"
    let block = NoteBlock(text: text, marks: [NoteTextMark(location: 0, length: text.utf16.count, bold: true)])
    let result = try #require(MarkdownTextLinks.render(block))
    #expect(result.block.id == block.id)
    #expect(result.block.text == "中文🌿 版本说明 和 [changelog](CHANGELOG.md) 后文")
    #expect(result.block.marks.allSatisfy { $0.bold })
    #expect(result.block.marks.first(where: { $0.link != nil })?.link == "https://example.com/v_(1)")
    #expect(result.offset(text.utf16.count) == result.block.text.utf16.count)
    #expect(MarkdownTextLinks.render(result.block) == nil)
    try NoteContent(blocks: [result.block]).validate()
}

@Test @MainActor func textLinksEscapedCopyAndSeveralLinksRenderInOneParagraph() throws {
    let source = #"This follows [Semantic Versioning]\(https://semver.org/). Contact [mail](mailto:hello@example.com)."#
    let parsed = try #require(MarkdownPasteParser.parse(source))
    #expect(parsed.blocks.count == 1)
    #expect(parsed.blocks[0].text == "This follows Semantic Versioning. Contact mail.")
    #expect(parsed.blocks[0].marks.compactMap(\.link) == ["https://semver.org/", "mailto:hello@example.com"])
    let mixed = try #require(MarkdownPasteParser.parse(#"Follow [Semver]\(https://semver.org/), see [changes](CHANGELOG.md)."#))
    #expect(mixed.blocks[0].text == "Follow Semver, see [changes](CHANGELOG.md).")
    let fullyEscaped = try #require(MarkdownTextLinks.render(NoteBlock(text: #"[label]\(https://example.com/\)"#)))
    #expect(fullyEscaped.block.text == "label")
}

@Test func textLinksLeaveCodeImagesInvalidAndEscapedLabelsAlone() {
    for source in ["`[code](https://example.com)`", "![image](https://example.com/a.png)", "[![badge](https://example.com/a.svg)](https://example.com)", "[broken](https://example.com", "[unsafe](javascript:alert(1))", #"\[literal](https://example.com)"#, "[local](LICENSE)"] {
        #expect(MarkdownTextLinks.render(NoteBlock(text: source)) == nil)
    }
    #expect(MarkdownTextLinks.render(NoteBlock(kind: .code, text: "[code](https://example.com)")) == nil)
    let text = "[code](https://example.com)"
    #expect(MarkdownTextLinks.render(NoteBlock(text: text, marks: [NoteTextMark(location: 0, length: text.utf16.count, code: true)])) == nil)
}

@MainActor private final class LinkUndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}

@Test @MainActor func textLinksExistingParagraphActionUsesUUIDUndoAndPersistence() throws {
    let target = NoteBlock(text: "Follow [Semantic Versioning](https://semver.org/).")
    let original = NoteContent(blocks: [NoteBlock(text: "another paragraph"), target])
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.isRichText = true; editor.isEditable = true; editor.configure(content: original)
    let delegate = LinkUndoDelegate(); delegate.history.groupsByEvent = false
    editor.delegate = delegate; editor.allowsUndo = true
    editor.setSelectedRange(NSRange(location: 3, length: 0))
    let menu = try #require(editor.makeTextActionMenu(blockID: target.id))
    #expect(menu.items.contains(where: { ($0.representedObject as? BlockMenuCommand)?.action == .renderTextLinks }))
    delegate.history.beginUndoGrouping()
    #expect(editor.performBlockAction(.renderTextLinks, blockID: target.id))
    delegate.history.endUndoGrouping()
    #expect(editor.content.blocks[0] == original.blocks[0])
    #expect(editor.content.blocks[1].text == "Follow Semantic Versioning.")
    let converted = editor.content
    delegate.history.undo(); #expect(editor.content == original)
    delegate.history.redo(); #expect(editor.content == converted)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = NoteFile(url: directory.appendingPathComponent("note.json"))
    var document = NoteDocument(); document.content = converted
    try file.save(document); #expect(try file.load().content == converted)
    editor.configure(content: original); editor.isEditable = false
    #expect(!editor.performBlockAction(.renderTextLinks, blockID: target.id))
    #expect(editor.content == original)
}

@Test @MainActor func textLinksPlainTextPasteStaysLiteralAndCodeHasNoLink() {
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.isRichText = true; editor.isEditable = true; editor.configure(content: NoteContent())
    let source = "Text [link](https://example.com)"
    editor.insertPastedText(source, interpretingMarkdown: false)
    #expect(editor.string == source && editor.content.blocks[0].marks.isEmpty)
    editor.configure(content: NoteContent(blocks: [NoteBlock(kind: .code)]))
    editor.insertPastedText(source)
    #expect(editor.content.blocks[0].text == source && editor.content.blocks[0].marks.isEmpty)
}
