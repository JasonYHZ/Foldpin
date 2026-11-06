import AppKit
import Testing
@testable import FoldpinCore

private let previewPixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aH1kAAAAASUVORK5CYII=")!

@Suite(.serialized) struct LinkPreviewImageTests {
    @Test func resolvesImageURLsAndRetainsOldSavedCards() throws {
        let url = URL(string: "https://example.com/start")!
        let redirected = URL(string: "https://example.org/blog/post/")!
        let card = LinkPreviewFetcher.parse("<meta property='og:image' content='../cover.jpg?a=1&amp;b=2'><title>Title</title>", url: url, baseURL: redirected)
        #expect(card.url == url.absoluteString)
        #expect(card.imageURL == "https://example.org/blog/cover.jpg?a=1&b=2")
        #expect(LinkPreviewFetcher.parse("<meta name='twitter:image' content='/fallback.png'>", url: url).imageURL == "https://example.com/fallback.png")
        for source in ["javascript:alert(1)", "file:///image.jpg", "https://user:password@example.org/a.jpg", "http://example.org/a.jpg"] {
            #expect(LinkPreviewFetcher.parse("<meta property='og:image' content='\(source)'>", url: url).imageURL == nil)
        }
        let old = Data(#"{"url":"https://example.com","title":"Old card","summary":"Text","siteName":"Example","state":"loaded"}"#.utf8)
        let decoded = try JSONDecoder().decode(NoteLinkPreview.self, from: old)
        #expect(decoded.thumbnail == nil && decoded.imageURL == nil && decoded.isValid)
    }

    @Test func thumbnailsAreSmallSanitizedAndOptional() throws {
        let data = try #require(LinkPreviewThumbnail.prepare(previewPixel))
        #expect(data.count <= LinkPreviewThumbnail.maximumStoredBytes && LinkPreviewThumbnail.isValid(data))
        #expect(LinkPreviewThumbnail.prepare(Data("not an image".utf8)) == nil)
        #expect(LinkPreviewThumbnail.prepare(Data(repeating: 0, count: LinkPreviewThumbnail.maximumDownloadBytes + 1)) == nil)
        var preview = NoteLinkPreview(url: "https://example.com", thumbnail: data)
        #expect(preview.isValid)
        preview.thumbnail = Data("bad".utf8)
        #expect(!preview.isValid)
        preview.thumbnail = Data(repeating: 0, count: LinkPreviewThumbnail.maximumStoredBytes + 1)
        #expect(!preview.isValid)
    }

    @Test func imageDownloadSuccessAndFailuresKeepMetadata() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PreviewImageURLProtocol.self]
        for outcome in ["ok", "missing", "oversized", "invalid", "binary", "unbounded"] {
            let preview = try await LinkPreviewFetcher.fetch(URL(string: "https://example.com/page-" + outcome)!, configuration: configuration)
            #expect(preview.title == "Metadata survives" && preview.state == .loaded)
            #expect(preview.imageURL?.contains("image-" + outcome) == true)
            #expect((preview.thumbnail != nil) == (outcome == "ok"))
        }
    }

    @Test @MainActor func thumbnailSurvivesSaveClipboardExportAndLayoutChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = NoteFile(url: root.appendingPathComponent("note.json"))
        let thumbnail = try #require(LinkPreviewThumbnail.prepare(previewPixel))
        let url = "https://example.com/a/long/path?query=preserved&more=yes"
        let preview = NoteLinkPreview(url: url, title: "Illustrated card", summary: "Description", state: .loaded, imageURL: "https://example.com/cover.png", thumbnail: thumbnail)
        var document = NoteDocument(); document.content = NoteContent(blocks: [NoteBlock(kind: .linkPreview, linkPreview: preview)])
        try file.save(document)
        #expect(try file.load() == document)
        let board = NSPasteboard(name: .init(UUID().uuidString)); defer { board.releaseGlobally() }
        try NoteClipboard.copy(document.content, file: file, to: board)
        #expect(board.string(forType: .string) == url)
        let richData = try #require(board.data(forType: .rtfd))
        let rich = try NSAttributedString(data: richData, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
        #expect(rich.attribute(.link, at: 0, effectiveRange: nil) as? URL == preview.destination)
        let html = String(decoding: try #require(board.data(forType: .html)), as: UTF8.self)
        #expect(html.contains("data:image/jpeg;base64," + thumbnail.base64EncodedString()))
        #expect(html.contains("/a/long/path?query=preserved&amp;more=yes"))
        let copied = try JSONDecoder().decode(NoteContent.self, from: #require(board.data(forType: NoteClipboard.blocksType)))
        #expect(copied == document.content)
        let source = NoteExportSource(document: document, assets: file.assetsURL)
        #expect(NoteExport.isArchive([source]))
        for format in NoteExportFormat.allCases {
            let entries = try NoteExport.entries([source], format: format)
            #expect(entries.count == 2 && entries.last?.data == thumbnail)
            #expect(entries.last?.path.hasSuffix("-link-preview.jpg") == true)
            #expect(String(decoding: try #require(entries.first?.data), as: UTF8.self).contains("assets/"))
            let destination = root.appendingPathComponent(format.rawValue + ".zip")
            try NoteExport.write([source], format: format, to: destination)
            #expect(try Data(contentsOf: destination).starts(with: [0x50, 0x4b]))
        }
        for width in [CGFloat(240), 360, 760] {
            let card = LinkPreviewAttachment.make(preview, width: width, color: .black)
            let pending = LinkPreviewAttachment.make(NoteLinkPreview(url: url), width: width, color: .black)
            #expect(card.bounds == pending.bounds)
            #expect(card.image?.accessibilityDescription?.contains(url) == true)
            let text = BlockTextCodec.render(document.content, color: .black, width: width, image: { _ in nil })
            #expect(text.attribute(.toolTip, at: 0, effectiveRange: nil) as? String == url)
            #expect(BlockTextCodec.read(text, typing: [:]).first?.block.linkPreview == preview)
        }
    }
}

private final class PreviewImageURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let isImage = url.path.hasPrefix("/image-")
        let outcome = url.lastPathComponent.split(separator: "-").last!
        let body: Data
        if !isImage { body = Data("<title>Metadata survives</title><meta property='og:image' content='/image-\(outcome)'>".utf8) }
        else if outcome == "invalid" { body = Data("not an image".utf8) }
        else if outcome == "unbounded" { body = Data(repeating: 0, count: LinkPreviewThumbnail.maximumDownloadBytes + 1) }
        else { body = previewPixel }
        var headers = ["Content-Type": isImage ? (outcome == "binary" ? "application/octet-stream" : "image/png") : "text/html"]
        if outcome != "unbounded" { headers["Content-Length"] = String(isImage && outcome == "oversized" ? LinkPreviewThumbnail.maximumDownloadBytes + 1 : body.count) }
        let response = HTTPURLResponse(url: url, statusCode: isImage && outcome == "missing" ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
