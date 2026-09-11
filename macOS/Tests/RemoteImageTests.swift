import AppKit
import Testing
@testable import FoldpinCore

private let badgeSVG = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="20"><linearGradient id="s" x2="0" y2="100%"><stop offset="0" stop-color="#bbb"/><stop offset="1" stop-color="#aaa"/></linearGradient><rect width="100" height="20" fill="url(#s)"/><text x="5" y="14" font-size="11">build: passing</text></svg>"##.utf8)

@Test @MainActor func remoteMarkdownBadgesKeepLinksAndText() throws {
    let content = try #require(MarkdownPasteParser.parse("**Before** [![npm version](https://img.shields.io/npm/v/library-name.svg)](https://www.npmjs.com/package/library-name) [![MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE) after"))
    #expect(content.blocks.map(\.kind) == [.paragraph, .image, .image, .paragraph])
    #expect(content.blocks.first?.marks.first?.bold == true)
    let images = content.blocks.compactMap(\.image)
    #expect(images.count == 2)
    #expect(images[0].name == "npm version")
    #expect(images[0].remoteState == .pending)
    #expect(images[0].clickableLink?.host == "www.npmjs.com")
    #expect(images[1].link == "LICENSE" && images[1].clickableLink == nil)
    #expect(images[0].sourceMarkdown?.contains("library-name.svg") == true)
    try content.validate()
    #expect(try JSONDecoder().decode(NoteContent.self, from: JSONEncoder().encode(content)) == content)
}

@Test @MainActor func remoteMarkdownReferencesAndLiteralBoundaries() throws {
    let reference = try #require(MarkdownPasteParser.parse("![徽章🌿][badge]\n\n[badge]: https://example.com/badge.svg"))
    #expect(reference.blocks.first?.image?.remoteSource == "https://example.com/badge.svg")
    for literal in [#"![badge]\(https://example.com/a.svg)"#, "![local](./a.png)", "![unsafe](file:///tmp/a.png)"] {
        let parsed = MarkdownPasteParser.parse("# Header\n\n" + literal)
        #expect(parsed?.blocks.contains(where: { $0.kind == .image }) == false)
    }
    let code = try #require(MarkdownPasteParser.parse("```markdown\n![badge](https://example.com/a.svg)\n```"))
    #expect(code.blocks.count == 1 && code.blocks[0].kind == .code)
    #expect(RemoteImageReference.downloadURL("https://user:secret@example.com/a") == nil)
    #expect(RemoteImageReference.linkURL("javascript:alert(1)") == nil)
}

@Test @MainActor func remotePlaceholderSavesWithoutAssetsButLoadedImageRequiresThem() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = NoteFile(url: directory.appendingPathComponent("note.json"))
    var document = NoteDocument()
    document.content = try #require(MarkdownPasteParser.parse("![badge](https://example.com/badge.svg)"))
    try file.save(document)
    #expect(try file.load().content == document.content)
    document.content.blocks[0].image?.remoteState = nil
    #expect(throws: (any Error).self) { try file.save(document) }
    document.content.blocks[0].image?.remoteState = .pending
    document.content.blocks[0].image?.remoteSource = nil
    #expect(throws: (any Error).self) { try document.validate() }
}

@Test func remoteSVGRejectsActiveAndExternalContent() throws {
    #expect(try SVGImageValidation.size(of: badgeSVG) == CGSize(width: 100, height: 20))
    let bodies = ["<script>alert(1)</script>", "<image href='https://example.com/x.png'/>", "<style>@import url(https://example.com/x)</style>", "<rect style='fill:red'/>", "<rect fill='url(#s) url(https://example.com/x)'/>", "<rect fill='u\\72l(https://example.com/x)'/>", "<use href='#loop' id='loop'/>", "<rect onclick='alert(1)'/>"]
    for body in bodies {
        let data = Data(("<svg xmlns='http://www.w3.org/2000/svg' width='100' height='20'>" + body + "</svg>").utf8)
        #expect(throws: (any Error).self) { try SVGImageValidation.size(of: data) }
    }
    #expect(throws: (any Error).self) { try SVGImageValidation.size(of: Data("<!DOCTYPE svg><svg width='1' height='1'/>".utf8)) }
    #expect(throws: (any Error).self) { try SVGImageValidation.size(of: Data("<svg width='100000' height='20'/>".utf8)) }
}

@Test @MainActor func remoteSVGCreatesLocalPNGAndExportsOriginal() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let image = try await RemoteImageImporter.prepare(badgeSVG, name: "badge", directory: directory)
    #expect(image.isSVG == true && image.displayWidth == 100)
    let file = NoteFile(url: directory.deletingLastPathComponent().appendingPathComponent("unused.json"), assetDirectory: directory)
    #expect(NSImage(contentsOf: file.imageURL(image.id)) != nil)
    #expect(try Data(contentsOf: file.imageURL(image.id, original: true)) == badgeSVG)
    let export = try MediaExport.image(at: file.imageURL(image.id, original: true), name: image.name, fallback: "Image", isSVG: image.isSVG == true)
    #expect(export.filename == "badge.svg" && export.contentType.identifier == "public.svg-image")
}

@MainActor private func remoteEditor(file: NoteFile) -> PaperTextView {
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.frame = NSRect(x: 0, y: 0, width: 500, height: 500)
    editor.textContainer?.size = NSSize(width: 450, height: CGFloat.greatestFiniteMagnitude)
    editor.isRichText = true; editor.isEditable = true; editor.file = file
    editor.configure(content: NoteContent())
    return editor
}

@Test @MainActor func remoteEditorDownloadsAndRetriesWithoutReplacingSurroundingEdits() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let editor = remoteEditor(file: NoteFile(url: directory.appendingPathComponent("note.json")))
    editor.fetchRemoteImage = { _ in throw RemoteImageImportError.response }
    editor.insertPastedText("Before\n\n[![badge](https://example.com/badge.svg)](https://example.com/project)\n\nAfter")
    for _ in 0..<100 where editor.content.blocks.compactMap(\.image).first?.remoteState != .failed { try await Task.sleep(for: .milliseconds(20)) }
    let block = try #require(editor.content.blocks.first(where: { $0.image != nil }))
    #expect(block.image?.remoteState == .failed)
    editor.fetchRemoteImage = { _ in badgeSVG }
    editor.enqueueRemoteImages([block.id])
    editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
    editor.insertText(" edited", replacementRange: editor.selectedRange())
    for _ in 0..<100 where editor.content.blocks.compactMap(\.image).first?.isRemotePlaceholder == true { try await Task.sleep(for: .milliseconds(20)) }
    let loaded = try #require(editor.content.blocks.first(where: { $0.id == block.id })?.image)
    #expect(!loaded.isRemotePlaceholder && loaded.isSVG == true)
    #expect(loaded.link == "https://example.com/project")
    #expect(editor.content.blocks.last?.text == "After edited")
}

@Test @MainActor func remoteEditorIgnoresDeletedBlockAndSaveFailure() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let editor = remoteEditor(file: NoteFile(url: directory.appendingPathComponent("note.json")))
    editor.fetchRemoteImage = { _ in try await Task.sleep(for: .milliseconds(100)); return badgeSVG }
    editor.insertPastedText("![badge](https://example.com/badge.svg)")
    editor.configure(content: NoteContent(blocks: [NoteBlock(text: "replacement")]))
    try await Task.sleep(for: .milliseconds(200))
    #expect(editor.content.blocks.count == 1 && editor.content.blocks[0].text == "replacement")
    editor.onRemoteImageCommit = { false }
    editor.insertPastedText("![badge](https://example.com/badge.svg)")
    try await Task.sleep(for: .milliseconds(200))
    #expect(editor.content.blocks.compactMap(\.image).first?.remoteState == .pending)
}

private final class RemoteImageURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let status = url.path == "/missing" ? 404 : 200
        let length = url.path == "/oversized" ? RemoteImageImporter.maximumBytes + 1 : badgeSVG.count
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/svg+xml", "Content-Length": "\(length)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: badgeSVG)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func remoteTransportAcceptsImageAndRejectsHTTPFailureAndOversize() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RemoteImageURLProtocol.self]
    let bytes = try await RemoteImageImporter.fetch(URL(string: "https://example.com/badge")!, configuration: configuration)
    #expect(bytes == badgeSVG)
    for path in ["missing", "oversized"] {
        do {
            _ = try await RemoteImageImporter.fetch(URL(string: "https://example.com/" + path)!, configuration: configuration)
            Issue.record("Expected a rejected image response")
        } catch is RemoteImageImportError { }
    }
}

@MainActor private final class RemoteUndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}

@Test @MainActor func remoteDownloadKeepsNativeUndoAndPortableLinks() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = NoteFile(url: directory.appendingPathComponent("note.json"))
    let editor = remoteEditor(file: file), delegate = RemoteUndoDelegate()
    delegate.history.groupsByEvent = false
    editor.delegate = delegate; editor.allowsUndo = true
    editor.fetchRemoteImage = { _ in badgeSVG }
    delegate.history.beginUndoGrouping()
    editor.insertPastedText("[![badge](https://example.com/badge.svg)](https://example.com/project)")
    let pending = editor.content
    delegate.history.endUndoGrouping()
    delegate.history.beginUndoGrouping()
    for _ in 0..<100 where editor.content.blocks.compactMap(\.image).first?.isRemotePlaceholder == true { try await Task.sleep(for: .milliseconds(20)) }
    let loaded = editor.content
    #expect(loaded.blocks.compactMap(\.image).first?.isSVG == true)
    if delegate.history.groupingLevel > 0 { delegate.history.endUndoGrouping() }
    delegate.history.undo()
    #expect(editor.content == pending)
    delegate.history.redo()
    #expect(editor.content == loaded)
    let board = NSPasteboard(name: NSPasteboard.Name("Foldpin-remote-image-test-\(UUID())"))
    defer { board.releaseGlobally() }
    try NoteClipboard.copy(loaded, file: file, to: board)
    #expect(board.string(forType: .html)?.contains("<a href=\"https://example.com/project\"><img") == true)
    let image = try #require(loaded.blocks.compactMap(\.image).first)
    #expect(try NoteClipboard.imageItem(image, file: file).data(forType: .png) != nil)
    try NoteClipboard.copy(pending, file: file, to: board)
    #expect(board.string(forType: .string)?.contains("https://example.com/badge.svg") == true)
}

@Test @MainActor func remoteMarkdownEmptyAltUnicodeAndParenthesizedURLs() throws {
    for source in ["![](https://example.com/a.png)", "[![](https://example.com/a.svg)](https://example.com)", "[![徽章🌿](https://example.com/a_(1).svg)](https://example.com/project_(1))", "![**bold** alt](https://example.com/a.svg)"] {
        let content = try #require(MarkdownPasteParser.parse(source))
        #expect(content.blocks.count == 1 && content.blocks[0].kind == .image)
        #expect(content.blocks[0].image?.remoteState == .pending)
        #expect(content.blocks[0].image?.name.contains("foldpin-empty") == false)
    }
    let literal = "![](https://example.com/a.png)"
    let code = try #require(MarkdownPasteParser.parse("```markdown\n" + literal + "\n```"))
    #expect(code.blocks[0].text == literal + "\n")
}

@Test @MainActor func remoteMarkdownLinkedReferencesAndMultilineAltKeepImage() throws {
    for source in ["[![badge][img]](https://example.com/project)\n\n[img]: https://example.com/badge.svg", "[![two\nlines](https://example.com/badge.svg)](https://example.com/project)"] {
        let content = try #require(MarkdownPasteParser.parse(source))
        let image = try #require(content.blocks.compactMap(\.image).first)
        #expect(image.remoteSource == "https://example.com/badge.svg")
        #expect(image.link == "https://example.com/project")
    }
}
