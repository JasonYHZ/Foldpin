import AppKit
import Testing
@testable import FoldpinCore

@Suite(.serialized) struct LinkPreviewTests {
    @Test func metadataUsesOpenGraphAndPlainHTMLWithoutExecutingMarkup() throws {
        let url = URL(string: "https://example.com/article?a=1&b=2")!
        let html = """
        <html><head><title>Fallback</title>
        <!-- <meta property="og:title" content="Ignore comment"> -->
        <script>const x = '<meta property="og:title" content="Ignore script">';</script>
        <META content='中文 &amp; Notes &#x1F4DD;' property='og:title'>
        <meta name=description content="Fallback description">
        <meta content="A &quot;small&quot; page > with <b>detail</b>." property="og:description">
        <meta property="og:site_name" content="Example">
        </head></html>
        """
        let preview = LinkPreviewFetcher.parse(html, url: url)
        #expect(preview.title == "中文 & Notes 📝")
        #expect(preview.summary == "A \"small\" page > with detail .")
        #expect(preview.siteName == "Example" && preview.state == .loaded && preview.url == url.absoluteString)
        #expect(preview.isValid)
        let fallback = LinkPreviewFetcher.parse("<title> Simple &amp; title </title><meta name='description' content='Some text'>", url: url)
        #expect(fallback.title == "Simple & title" && fallback.summary == "Some text")
        #expect(LinkPreviewFetcher.parse("<body>No metadata</body>", url: url).displayTitle == "example.com")
        #expect(LinkPreviewFetcher.parse("<title>" + String(repeating: "字", count: 1000) + "</title>", url: url).title.count == 512)
        #expect(PastedWebLinks.standalone(" https://example.com/a_b\n") == URL(string: "https://example.com/a_b"))
        for text in ["javascript:alert(1)", "file:///etc/passwd", "https://user:secret@example.com", "look https://example.com"] {
            #expect(PastedWebLinks.standalone(text) == nil)
        }
    }

    @Test func inlineDetectionPreservesUnicodeFormattingAndExplicitLinks() throws {
        let text = "中文📝 https://example.com/a_b, then https://example.org/page."
        let first = (text as NSString).range(of: "https://example.com/a_b")
        let second = (text as NSString).range(of: "https://example.org/page")
        let block = NoteBlock(text: text, marks: [.init(location: first.location, length: first.length, bold: true)])
        let result = PastedWebLinks.recognizing(in: block)
        #expect(result.text == text)
        #expect(result.marks.contains { $0.location == first.location && $0.length == first.length && $0.bold && $0.link == "https://example.com/a_b" })
        #expect(result.marks.contains { $0.location == second.location && $0.link == "https://example.org/page" })
        try NoteContent(blocks: [result]).validate()
        var code = block; code.kind = .code
        #expect(PastedWebLinks.recognizing(in: code) == code)
        var styled = block; styled.marks = [.init(location: first.location, length: first.length, code: true),
            .init(location: second.location, length: second.length, link: "https://other.example")]
        #expect(PastedWebLinks.recognizing(in: styled) == styled)
    }

    @Test @MainActor func cardPersistsCopiesExportsWithoutNativeTextLinkDecoration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = NoteFile(url: root.appendingPathComponent("note.json"))
        let preview = NoteLinkPreview(url: "https://example.com/a?x=1&y=2", title: "<Title> & 中文", summary: "<script>literal</script>", siteName: "Example", state: .loaded)
        let block = NoteBlock(kind: .linkPreview, linkPreview: preview)
        var document = NoteDocument(); document.content = NoteContent(blocks: [block, NoteBlock(text: "after")])
        try document.content.validate()
        try file.save(document)
        #expect(try file.load() == document)
        #expect(!document.content.isBlankForClosing && !document.content.isEmpty)
        #expect(throws: NoteFileError.self) { try NoteContent(blocks: [NoteBlock(kind: .linkPreview)]).validate() }
        #expect(throws: NoteFileError.self) { try NoteContent(blocks: [NoteBlock(linkPreview: preview)]).validate() }
        let rendered = BlockTextCodec.render(document.content, color: .black, width: 340, image: { _ in nil })
        #expect(BlockTextCodec.read(rendered, typing: [:]).map(\.block) == document.content.blocks)
        #expect(rendered.attribute(.link, at: 0, effectiveRange: nil) == nil)
        let board = NSPasteboard(name: .init(UUID().uuidString)); defer { board.releaseGlobally() }
        try NoteClipboard.copy(document.content, file: file, to: board)
        #expect(board.string(forType: .string)?.contains(preview.url) == true)
        let data = try #require(board.data(forType: NoteClipboard.blocksType))
        #expect(try JSONDecoder().decode(NoteContent.self, from: data) == document.content)
        let copiedHTML = String(data: try #require(board.data(forType: .html)), encoding: .utf8)!
        #expect(copiedHTML.contains("&lt;Title&gt;") && !copiedHTML.contains("<script>"))
        let source = NoteExportSource(document: document, assets: file.assetsURL)
        #expect(!NoteExport.isArchive([source]))
        for format in NoteExportFormat.allCases {
            let data = try #require(NoteExport.entries([source], format: format).first?.data)
            let body = String(decoding: data, as: UTF8.self)
            #expect(body.contains("example.com/a?x=1"))
            #expect(!body.contains("<script>"))
        }
    }

    @Test @MainActor func pasteLoadsWithoutExtraUndoStepAndRedoKeepsMetadata() async throws {
        let editor = makeEditor()
        let undo = try #require(editor.undoManager)
        editor.fetchLinkPreview = { url in
            try await Task.sleep(for: .milliseconds(30))
            return NoteLinkPreview(url: url.absoluteString, title: "Saved page", summary: "Description", state: .loaded)
        }
        let before = editor.content
        undo.beginUndoGrouping(); editor.insertPastedText("https://example.com/a_b"); undo.endUndoGrouping()
        let selection = editor.selectedRange()
        #expect(editor.content.blocks.first?.linkPreview?.state == .pending)
        for _ in 0..<100 where editor.content.blocks.first?.linkPreview?.state == .pending { try await Task.sleep(for: .milliseconds(10)) }
        #expect(editor.content.blocks.first?.linkPreview?.title == "Saved page")
        #expect(editor.selectedRange() == selection)
        undo.undo()
        #expect(editor.content == before)
        undo.redo()
        for _ in 0..<100 where editor.content.blocks.first?.linkPreview?.state == .pending { try await Task.sleep(for: .milliseconds(10)) }
        #expect(editor.content.blocks.first?.linkPreview?.title == "Saved page")
        let id = try #require(editor.content.blocks.first?.id)
        var opened: URL?
        editor.openWebLink = { opened = $0; return true }
        #expect(editor.performBlockAction(.openLinkPreview, blockID: id))
        #expect(opened == URL(string: "https://example.com/a_b"))
        opened = nil
        let surface = try #require(editor.blockSurfaces().first { $0.blockID == id })
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: editor.convert(NSPoint(x: surface.rect.midX, y: surface.rect.midY), to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        editor.mouseDown(with: event)
        #expect(opened == URL(string: "https://example.com/a_b"))
        undo.beginUndoGrouping(); #expect(editor.performBlockAction(.restoreLinkText, blockID: id)); undo.endUndoGrouping()
        #expect(editor.content.blocks.first?.text == "https://example.com/a_b")
        #expect(editor.content.blocks.first?.marks.first?.link == "https://example.com/a_b")
        undo.undo(); #expect(editor.content.blocks.first?.linkPreview?.title == "Saved page")
    }

    @Test @MainActor func typingDuringFetchAndUndoBeforeCompletionDoNotLoseEdits() async throws {
        let editor = makeEditor(); let undo = try #require(editor.undoManager)
        editor.fetchLinkPreview = { url in
            try await Task.sleep(for: .milliseconds(70))
            return NoteLinkPreview(url: url.absoluteString, title: "Loaded", state: .loaded)
        }
        undo.beginUndoGrouping(); editor.insertPastedText("https://example.com"); undo.endUndoGrouping()
        undo.beginUndoGrouping(); editor.insertText("after", replacementRange: editor.selectedRange()); undo.endUndoGrouping()
        try await Task.sleep(for: .milliseconds(130))
        #expect(editor.content.blocks.last?.text == "after")
        #expect(editor.content.blocks.first?.linkPreview?.title == "Loaded")
        undo.undo(); #expect(editor.content.blocks.last?.text == "")
        undo.undo(); #expect(editor.content.isBlankForClosing)
        undo.beginUndoGrouping(); editor.insertPastedText("https://another.example"); undo.endUndoGrouping()
        undo.undo()
        try await Task.sleep(for: .milliseconds(130))
        #expect(editor.content.isBlankForClosing && !editor.hasPendingLibraryFileWork)
    }

    @Test @MainActor func failedFetchAndCompositionRetainLinkAndInput() async throws {
        let editor = makeEditor(); let undo = try #require(editor.undoManager)
        editor.fetchLinkPreview = { _ in throw LinkPreviewFetcher.Failure.response }
        undo.beginUndoGrouping(); editor.insertPastedText("https://example.com"); undo.endUndoGrouping()
        for _ in 0..<100 where editor.content.blocks.first?.linkPreview?.state == .pending { try await Task.sleep(for: .milliseconds(10)) }
        #expect(editor.content.blocks.first?.linkPreview?.state == .unavailable)
        let id = try #require(editor.content.blocks.first?.id)
        editor.fetchLinkPreview = { url in
            try await Task.sleep(for: .milliseconds(25))
            return NoteLinkPreview(url: url.absoluteString, title: "Recovered", state: .loaded)
        }
        editor.enqueueLinkPreviews([id])
        undo.beginUndoGrouping()
        editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
        undo.endUndoGrouping()
        try await Task.sleep(for: .milliseconds(80))
        #expect(editor.hasMarkedText())
        #expect(editor.content.blocks.first?.linkPreview?.title != "Recovered")
        editor.unmarkText()
        try await Task.sleep(for: .milliseconds(150))
        #expect(editor.content.blocks.last?.text == "中文")
        #expect(editor.content.blocks.first?.linkPreview?.title == "Recovered")
    }

    @Test @MainActor func inlineCodePlainTextAndReadOnlyPaths() throws {
        let url = "https://example.com/a_b"
        let inline = makeEditor(NoteContent(plainText: "See  after"))
        inline.setSelectedRange(NSRange(location: 4, length: 0))
        inline.undoManager?.beginUndoGrouping(); inline.insertPastedText(url); inline.undoManager?.endUndoGrouping()
        #expect(inline.content.plainText == "See " + url + " after")
        #expect(inline.content.blocks.first?.linkPreview == nil)
        #expect(inline.content.blocks.first?.marks.first?.link == url)
        for (content, markdown) in [(NoteContent(blocks: [NoteBlock(kind: .code)]), true), (NoteContent(), false)] {
            let editor = makeEditor(content)
            editor.undoManager?.beginUndoGrouping(); editor.insertPastedText(url, interpretingMarkdown: markdown); editor.undoManager?.endUndoGrouping()
            #expect(editor.content.blocks.first?.text == url)
            #expect(editor.content.blocks.first?.linkPreview == nil && editor.content.blocks.first?.marks.isEmpty == true)
        }
        let readOnly = makeEditor(); readOnly.isEditable = false
        readOnly.insertPastedText(url)
        #expect(readOnly.content.isBlankForClosing)
    }

    @Test func transportRejectsHTTPFailuresNonHTMLAndOversizedResponses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PreviewURLProtocol.self]
        let success = try await LinkPreviewFetcher.fetch(URL(string: "https://example.com/ok")!, configuration: configuration)
        #expect(success.title == "Transport title" && success.state == .loaded)
        for path in ["missing", "binary", "oversized", "unbounded"] {
            do {
                _ = try await LinkPreviewFetcher.fetch(URL(string: "https://example.com/" + path)!, configuration: configuration)
                Issue.record("Expected rejected response: \(path)")
            } catch is LinkPreviewFetcher.Failure { }
        }
    }

    @Test @MainActor func nativeCardAppearanceSamples() throws {
        let preview = NoteLinkPreview(url: "https://example.com/notes", title: "A small place for your ideas · 随手记录", summary: "Capture a thought, keep it in view, and find it again. A compact preview of the page you saved.", siteName: "Example", state: .loaded)
        let size = NSSize(width: 460, height: 610)
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor(calibratedWhite: 0.94, alpha: 1).setFill(); rect.fill()
            for (index, background, ink) in [(0, NSColor(calibratedRed: 0.98, green: 0.94, blue: 0.75, alpha: 1), NSColor(calibratedWhite: 0.2, alpha: 1)),
                                            (1, NSColor(calibratedWhite: 0.12, alpha: 1), NSColor(calibratedWhite: 0.93, alpha: 1)),
                                            (2, NSColor.white, NSColor(calibratedWhite: 0.2, alpha: 1))] {
                let y = CGFloat(index * 200 + 5)
                background.setFill(); NSRect(x: 10, y: y, width: 440, height: 195).fill()
                let card = LinkPreviewAttachment.make(preview, width: 420, color: ink)
                card.image?.draw(in: NSRect(x: 20, y: y + 6, width: 418, height: 184))
            }
            return true
        }
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/foldpin-link-preview-samples.png"))
    }

    @MainActor private func makeEditor(_ content: NoteContent = NoteContent()) -> PaperTextView {
        let editor = PaperTextView(usingTextLayoutManager: true)
        editor.frame = NSRect(x: 0, y: 0, width: 500, height: 500)
        editor.textContainer?.size = NSSize(width: 450, height: CGFloat.greatestFiniteMagnitude)
        editor.isRichText = true; editor.isEditable = true; editor.allowsUndo = true
        editor.sessionUndoManager = UndoManager(); editor.sessionUndoManager?.groupsByEvent = false
        editor.configure(content: content)
        return editor
    }
}

private final class PreviewURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let body = url.path == "/unbounded" ? Data(repeating: 65, count: LinkPreviewFetcher.maximumBytes + 1) : Data("<title>Transport title</title>".utf8)
        let status = url.path == "/missing" ? 404 : 200
        var headers = ["Content-Type": url.path == "/binary" ? "application/pdf" : "text/html; charset=utf-8"]
        if url.path != "/unbounded" { headers["Content-Length"] = String(url.path == "/oversized" ? LinkPreviewFetcher.maximumBytes + 1 : body.count) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
