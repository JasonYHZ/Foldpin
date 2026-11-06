import AppKit
import Testing
@testable import FoldpinCore

@Suite(.serialized) struct LinkCardConversionTests {
    @Test func resolvesBareAndStyledLinksWithoutGuessingAmongMultipleLinks() throws {
        let bare = NoteBlock(text: "https://example.com/a")
        #expect(LinkCardConversion.target(in: bare)?.url == bare.text)
        let named = NoteBlock(text: "Read this", marks: [
            .init(location: 0, length: 5, link: "https://example.com/a"),
            .init(location: 5, length: 4, bold: true, link: "https://example.com/a")])
        let target = try #require(LinkCardConversion.target(in: named))
        #expect(target.label == "Read this" && target.range == NSRange(location: 0, length: 9))
        let multiple = NoteBlock(text: "first second", marks: [
            .init(location: 0, length: 5, link: "https://example.com/first"),
            .init(location: 6, length: 6, link: "https://example.com/second")])
        #expect(LinkCardConversion.target(in: multiple) == nil)
        #expect(LinkCardConversion.target(in: multiple, selection: NSRange(location: 8, length: 0))?.url == "https://example.com/second")
        #expect(LinkCardConversion.target(in: multiple, selection: NSRange(location: 1, length: 2))?.url == "https://example.com/first")
        #expect(LinkCardConversion.target(in: NoteBlock(kind: .code, text: bare.text)) == nil)
        #expect(LinkCardConversion.target(in: NoteBlock(text: bare.text, marks: [.init(location: 0, length: bare.text.utf16.count, code: true)])) == nil)
        #expect(LinkCardConversion.target(in: NoteBlock(text: "Email", marks: [.init(location: 0, length: 5, link: "mailto:test@example.com")])) == nil)
    }

    @Test @MainActor func bothMenusExposeConversionForTextAndCard() throws {
        let block = NoteBlock(text: "https://example.com")
        let editor = makeEditor(NoteContent(blocks: [block]))
        let blockMenu = try #require(editor.makeBlockActionMenu(blockID: block.id))
        #expect(conversion(in: blockMenu) != nil)
        let textMenu = try #require(editor.makeTextActionMenu(blockID: block.id))
        #expect(conversion(in: textMenu) != nil)
        let plain = NoteBlock(text: "not a link")
        editor.configure(content: NoteContent(blocks: [plain]))
        #expect(conversion(in: try #require(editor.makeTextActionMenu(blockID: plain.id))) == nil)
        let card = NoteBlock(kind: .linkPreview, linkPreview: NoteLinkPreview(url: block.text))
        editor.configure(content: NoteContent(blocks: [card]))
        let menu = try #require(editor.makeBlockActionMenu(blockID: card.id))
        #expect(menu.items.contains { ($0.representedObject as? BlockMenuCommand)?.action == .restoreLinkText })
        #expect(conversion(in: menu) == nil)
    }

    @Test @MainActor func pointerTargetWinsOverCaretAndSelectedText() throws {
        let block = NoteBlock(text: "first second", marks: [
            .init(location: 0, length: 5, link: "https://example.com/first"),
            .init(location: 6, length: 6, link: "https://example.com/second")])
        let editor = makeEditor(NoteContent(blocks: [block]))
        editor.setSelectedRange(NSRange(location: 0, length: 12))
        let menu = try #require(editor.makeTextActionMenu(blockID: block.id, linkPosition: 8))
        let target = try #require(conversion(in: menu))
        #expect(target.url == "https://example.com/second")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.undoManager?.beginUndoGrouping()
        #expect(editor.performBlockAction(.convertTextLink(target), blockID: block.id))
        editor.undoManager?.endUndoGrouping()
        #expect(editor.content.blocks[0].text == "first ")
        #expect(editor.content.blocks[0].marks.first?.link == "https://example.com/first")
        #expect(editor.content.blocks[1].linkPreview?.url == "https://example.com/second")
    }

    @Test @MainActor func conversionPreservesSurroundingUnicodeStylesAndSingleUndo() async throws {
        let block = NoteBlock(text: "中文📝 Read this 后文", marks: [
            .init(location: 0, length: 5, bold: true),
            .init(location: 5, length: 5, link: "https://example.com/article"),
            .init(location: 10, length: 4, italic: true, link: "https://example.com/article"),
            .init(location: 14, length: 3, strikethrough: true)])
        let content = NoteContent(blocks: [block])
        let editor = makeEditor(content)
        let target = try #require(LinkCardConversion.target(in: block))
        #expect(target.label == "Read this")
        let undo = try #require(editor.undoManager)
        undo.beginUndoGrouping()
        #expect(editor.performBlockAction(.convertTextLink(target), blockID: block.id))
        undo.endUndoGrouping()
        #expect(editor.content.blocks.map(\.kind) == [.paragraph, .linkPreview, .paragraph])
        #expect(editor.content.blocks[0].text == "中文📝 " && editor.content.blocks[0].marks.first?.bold == true)
        #expect(editor.content.blocks[2].text == " 后文" && editor.content.blocks[2].marks.first?.strikethrough == true)
        for _ in 0..<100 where editor.content.blocks[1].linkPreview?.state == .pending { try await Task.sleep(for: .milliseconds(10)) }
        #expect(editor.content.blocks[1].linkPreview?.textLabel == "Read this")
        #expect(editor.content.blocks[1].linkPreview?.title == "Fetched title")
        try editor.content.validate()
        undo.undo(); #expect(editor.content == content)
        undo.redo()
        for _ in 0..<100 where editor.content.blocks[1].linkPreview?.state == .pending { try await Task.sleep(for: .milliseconds(10)) }
        #expect(editor.content.blocks[1].linkPreview?.textLabel == "Read this")
        #expect(editor.content.blocks[1].linkPreview?.title == "Fetched title")
    }

    @Test @MainActor func roundTripPreservesLabelAndReusesSavedImageWithoutNetwork() throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aH1kAAAAASUVORK5CYII=")!
        let thumbnail = try #require(LinkPreviewThumbnail.prepare(png))
        let preview = NoteLinkPreview(url: "https://example.com/article", title: "Fetched title", summary: "Saved description", state: .loaded,
            imageURL: "https://example.com/cover.jpg", thumbnail: thumbnail, textLabel: "Read this")
        let card = NoteBlock(kind: .linkPreview, linkPreview: preview)
        let editor = makeEditor(NoteContent(blocks: [card]))
        editor.fetchLinkPreview = { _ in Issue.record("Round-trip should reuse the saved card"); throw LinkPreviewFetcher.Failure.response }
        let undo = try #require(editor.undoManager)
        undo.beginUndoGrouping(); #expect(editor.performBlockAction(.restoreLinkText, blockID: card.id)); undo.endUndoGrouping()
        let text = try #require(editor.content.blocks.first)
        #expect(text.text == "Read this" && text.marks.first?.link == preview.url)
        let target = try #require(LinkCardConversion.target(in: text))
        undo.beginUndoGrouping(); #expect(editor.performBlockAction(.convertTextLink(target), blockID: text.id)); undo.endUndoGrouping()
        #expect(editor.content.blocks.first?.linkPreview == preview)
        #expect(!editor.hasPendingLibraryFileWork)
        let encoded = try JSONEncoder().encode(editor.content)
        #expect(try JSONDecoder().decode(NoteContent.self, from: encoded).blocks.first?.linkPreview?.textLabel == "Read this")
        undo.undo(); #expect(editor.content.blocks.first?.text == "Read this")
        undo.undo(); #expect(editor.content.blocks.first?.linkPreview == preview)
    }

    @Test @MainActor func failedFetchDoesNotLeakNamedLabelIntoOtherCards() async throws {
        let url = "https://example.com/article"
        let block = NoteBlock(text: "Read this", marks: [.init(location: 0, length: 9, link: url)])
        let editor = makeEditor(NoteContent(blocks: [block]))
        editor.fetchLinkPreview = { _ in throw LinkPreviewFetcher.Failure.response }
        let target = try #require(LinkCardConversion.target(in: block))
        editor.undoManager?.beginUndoGrouping()
        #expect(editor.performBlockAction(.convertTextLink(target), blockID: block.id))
        editor.undoManager?.endUndoGrouping()
        for _ in 0..<100 where editor.content.blocks.first?.linkPreview?.state == .pending { try await Task.sleep(for: .milliseconds(10)) }
        #expect(editor.content.blocks.first?.linkPreview?.textLabel == "Read this")
        editor.undoManager?.beginUndoGrouping(); editor.insertPastedText(url); editor.undoManager?.endUndoGrouping()
        let cards = editor.content.blocks.compactMap(\.linkPreview)
        #expect(cards.count == 2)
        #expect(cards.last?.textLabel == nil)
    }

    @Test @MainActor func staleReadOnlyAndCompositionActionsCannotReplaceText() throws {
        let block = NoteBlock(text: "https://example.com")
        let editor = makeEditor(NoteContent(blocks: [block]))
        let menu = try #require(editor.makeTextActionMenu(blockID: block.id))
        let target = try #require(conversion(in: menu))
        var edited = block; edited.text = "different text"
        editor.configure(content: NoteContent(blocks: [edited]))
        #expect(!editor.performBlockAction(.convertTextLink(target), blockID: block.id))
        #expect(editor.content.blocks.first?.text == "different text")
        editor.configure(content: NoteContent(blocks: [block])); editor.isEditable = false
        #expect(!editor.performBlockAction(.convertTextLink(target), blockID: block.id))
        editor.isEditable = true
        editor.undoManager?.beginUndoGrouping()
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        editor.undoManager?.endUndoGrouping()
        #expect(editor.hasMarkedText())
        #expect(!editor.performBlockAction(.convertTextLink(target), blockID: block.id))
        editor.unmarkText()
    }

    @MainActor private func conversion(in menu: NSMenu) -> LinkCardConversion.Target? {
        for item in menu.items {
            if case .convertTextLink(let target) = (item.representedObject as? BlockMenuCommand)?.action { return target }
        }
        return nil
    }

    @MainActor private func makeEditor(_ content: NoteContent) -> PaperTextView {
        let editor = PaperTextView(usingTextLayoutManager: true)
        editor.frame = NSRect(x: 0, y: 0, width: 500, height: 500)
        editor.textContainer?.size = NSSize(width: 450, height: CGFloat.greatestFiniteMagnitude)
        editor.isRichText = true; editor.isEditable = true; editor.allowsUndo = true
        editor.sessionUndoManager = UndoManager(); editor.sessionUndoManager?.groupsByEvent = false
        editor.fetchLinkPreview = { url in NoteLinkPreview(url: url.absoluteString, title: "Fetched title", state: .loaded) }
        editor.configure(content: content)
        return editor
    }
}
