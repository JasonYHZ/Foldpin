import Foundation
import Testing
@testable import FoldpinCore

private func exportDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private func extractExport(_ zip: URL, to directory: URL) throws {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", zip.path, directory.path]
    try process.run(); process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

@Test func noteExportTextFormatsPreserveStructureAndEscapeContent() throws {
    let root = try exportDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    var note = NoteDocument()
    note.content = NoteContent(blocks: [
        NoteBlock(kind: .heading, text: "设计 <script>alert(1)</script>"),
        NoteBlock(text: "粗体与链接", marks: [NoteTextMark(location: 0, length: 2, bold: true), NoteTextMark(location: 3, length: 2, link: "https://example.com/?a=1&b=2")]),
        NoteBlock(kind: .task, text: "已完成", isChecked: true),
        NoteBlock(kind: .orderedList, text: "one"), NoteBlock(kind: .orderedList, text: "two"),
        NoteBlock(kind: .quote, text: "line1\nline2"),
        NoteBlock(kind: .code, text: "let x = \"```\"\n<script>", language: .swift),
        NoteBlock(kind: .divider),
        NoteBlock(kind: .table, table: NoteTable(rows: [["列|一", "列二"], ["a\nb", "<x>"]], headerRow: true)),
        NoteBlock(kind: .table, table: NoteTable(rows: [["无标题", "value"]]))
    ])
    let source = NoteExportSource(document: note, assets: root)
    #expect(!NoteExport.isArchive([source]))
    let md = try #require(NoteExport.entries([source], format: .markdown).first?.data).flatMapString
    #expect(md.contains("**粗体**") && md.contains("[链接](<https://example.com/?a=1&b=2>)"))
    #expect(md.contains("- [x] 已完成") && md.contains("2. two"))
    #expect(md.contains("````swift\nlet x") && md.contains("\n````"))
    #expect(md.contains("列\\|一") && md.contains("<table>"))
    let html = try #require(NoteExport.entries([source], format: .html).first?.data).flatMapString
    #expect(!html.contains("<script>"))
    #expect(html.contains("&lt;script&gt;") && html.contains("<strong>粗体</strong>"))
    #expect(html.contains("disabled checked") && html.contains("<ol>") && html.contains("<th>列|一</th>"))
    let destination = root.appendingPathComponent("text.md")
    try Data("previous export".utf8).write(to: destination)
    try NoteExport.write([source], format: .markdown, to: destination)
    #expect(try String(contentsOf: destination, encoding: .utf8) == md)
    #expect(source.document == note)
}

@Test func noteExportPackagesOriginalMediaAndSameNamedNotes() throws {
    let root = try exportDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let assetRoot = root.appendingPathComponent("assets")
    try FileManager.default.createDirectory(at: assetRoot, withIntermediateDirectories: true)
    let attachment = NoteAttachment(name: "报告 #1 [修订].pdf", byteCount: 2_100_000)
    let fileURL = attachment.url(in: assetRoot.appendingPathComponent("files"))
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fileBytes = Data(repeating: 0xa7, count: Int(attachment.byteCount)); try fileBytes.write(to: fileURL)
    let audio = NoteAudio(name: "声音", fileExtension: "m4a", duration: 1)
    let video = NoteVideo(name: "视频", fileExtension: "mp4", duration: 2, pixelWidth: 16, pixelHeight: 16)
    let image = NoteImage(id: UUID(), name: "原图.png", pixelWidth: 1, pixelHeight: 1)
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aH1kAAAAASUVORK5CYII=")!
    try png.write(to: assetRoot.appendingPathComponent(image.id.uuidString + ".original"))
    try png.write(to: assetRoot.appendingPathComponent(image.id.uuidString + ".png"))
    try Data("audio bytes".utf8).write(to: assetRoot.appendingPathComponent(audio.id.uuidString + ".m4a"))
    try Data("video bytes".utf8).write(to: assetRoot.appendingPathComponent(video.id.uuidString + ".mp4"))
    var note = NoteDocument(); note.content = NoteContent(blocks: [NoteBlock(text: "同名纸片"), NoteBlock(kind: .image, image: image), NoteBlock(kind: .audio, audio: audio), NoteBlock(kind: .video, video: video), NoteBlock(kind: .file, attachment: attachment)])
    let source = NoteExportSource(document: note, assets: assetRoot)
    var duplicate = note; duplicate.id = UUID()
    let notes = [source, NoteExportSource(document: duplicate, assets: assetRoot)]
    #expect(NoteExport.isArchive([source]))
    for format in NoteExportFormat.allCases {
        let entries = try NoteExport.entries(notes, format: format)
        #expect(entries.count == 12 && Set(entries.map(\.path)).count == entries.count)
        let zip = root.appendingPathComponent(format.rawValue + ".zip")
        try NoteExport.write(notes, format: format, to: zip)
        let expanded = root.appendingPathComponent(format.rawValue)
        try extractExport(zip, to: expanded)
        for entry in entries {
            let actual = try Data(contentsOf: expanded.appendingPathComponent(entry.path))
            if let expected = entry.data { #expect(actual == expected) }
            else if let url = entry.source { #expect(actual == (try Data(contentsOf: url))) }
        }
        let body = try #require(entries.first?.data).flatMapString
        #expect(body.contains("assets/"))
        #expect(!body.contains(assetRoot.path) && !body.contains("file://"))
        #expect(body.contains("%23") && body.contains("%5B"))
        if format == .html { #expect(body.contains("<audio controls") && body.contains("<video controls")) }
    }
}

@Test func noteExportFailurePreservesDestinationAndRejectsPendingMedia() throws {
    let root = try exportDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("keep.zip")
    let previous = Data("keep existing export".utf8); try previous.write(to: destination)
    var note = NoteDocument(); note.content = NoteContent(blocks: [NoteBlock(kind: .file, attachment: NoteAttachment(name: "missing.pdf", byteCount: 1))])
    #expect(throws: (any Error).self) { try NoteExport.write([NoteExportSource(document: note, assets: root)], format: .html, to: destination) }
    #expect(try Data(contentsOf: destination) == previous)
    var audio = NoteAudio(name: "Recording", fileExtension: "m4a", duration: 0); audio.isDraft = true
    note.content = NoteContent(blocks: [NoteBlock(kind: .audio, audio: audio)])
    #expect(throws: NoteExportError.self) { try NoteExport.write([NoteExportSource(document: note, assets: root)], format: .markdown, to: destination) }
    #expect(try Data(contentsOf: destination) == previous)
    var first = NoteDocument(); first.text = "same"; var second = first; second.id = UUID()
    #expect(NoteExport.isArchive([.init(document: first, assets: root), .init(document: second, assets: root)]))
    #expect(NoteExport.filename("../../a:b\\c\n") == "-..-a-b-c-")
    let longName = NoteExport.assetFilename(String(repeating: "纸", count: 100) + ".pdf")
    #expect(longName.hasSuffix(".pdf") && longName.utf8.count < 200)
}

@Test func noteExportCancellationKeepsExistingFile() async throws {
    let root = try exportDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("keep.md")
    let before = Data("keep".utf8); try before.write(to: destination)
    var document = NoteDocument(); document.text = "new content"
    let source = NoteExportSource(document: document, assets: root)
    let task = Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        try NoteExport.write([source], format: .markdown, to: destination)
    }
    do { try await task.value; Issue.record("Cancelled export unexpectedly succeeded") }
    catch { #expect(error is CancellationError) }
    #expect(try Data(contentsOf: destination) == before)
}

private extension Data { var flatMapString: String { String(decoding: self, as: UTF8.self) } }
