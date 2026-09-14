import Foundation

nonisolated enum NoteExportFormat: String, CaseIterable, Sendable {
    case markdown, html
    var fileExtension: String { self == .markdown ? "md" : "html" }
    var title: String { self == .markdown ? "Markdown" : "HTML" }
}

nonisolated struct NoteExportSource: Sendable {
    let document: NoteDocument
    let assets: URL
    var title: String { document.content.blocks.lazy.map(\.plainText).first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.components(separatedBy: .newlines).first ?? "Untitled" }
    var hasResources: Bool { document.content.blocks.contains { $0.image != nil || $0.audio != nil || $0.video != nil || $0.attachment != nil } }
}

nonisolated enum NoteExportError: Error {
    case unavailable, pending, changedResource
}

/// A snapshot of selected documents; resources are read only during the export.
nonisolated enum NoteExport {
    struct Entry: Sendable {
        let path: String
        var data: Data? = nil
        var source: URL? = nil
    }
    static func isArchive(_ notes: [NoteExportSource]) -> Bool { notes.count > 1 || notes.contains(where: \.hasResources) }
    static func filename(_ text: String) -> String {
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:\\"))
        let cleaned = text.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        var result = ""
        for character in cleaned {
            guard result.utf8.count + String(character).utf8.count <= 128 else { break }
            result.append(character)
        }
        return result.isEmpty ? "Untitled" : result
    }
    static func assetFilename(_ text: String) -> String {
        let ext = (text as NSString).pathExtension
        guard !ext.isEmpty else { return filename(text) }
        return filename((text as NSString).deletingPathExtension) + "." + String(filename(ext).prefix(16))
    }
    static func entries(_ notes: [NoteExportSource], format: NoteExportFormat) throws -> [Entry] {
        guard !notes.isEmpty else { throw NoteExportError.unavailable }
        var result: [Entry] = []
        for (index, note) in notes.enumerated() {
            try Task.checkCancellation()
            try note.document.validate()
            let prefix = notes.count > 1 ? String(format: "%03d", index + 1) + "-" + filename(note.title) + "/" : ""
            var resources: [Entry] = []
            var paths: [UUID: (String, String?)] = [:]
            func add(_ source: URL, name: String) throws -> String {
                let info = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true else { throw NoteExportError.unavailable }
                let path = "assets/" + name
                if !resources.contains(where: { $0.path == prefix + path }) { resources.append(Entry(path: prefix + path, source: source)) }
                return urlPath(path)
            }
            for block in note.document.content.blocks {
                if let image = block.image {
                    guard !image.isRemotePlaceholder else { throw NoteExportError.pending }
                    let original = note.assets.appendingPathComponent(image.id.uuidString + ".original")
                    let media = try MediaExport.image(at: original, name: image.name, fallback: "Image", isSVG: image.isSVG == true)
                    let source = try add(original, name: image.id.uuidString + "-" + assetFilename(media.filename))
                    let preview = try add(note.assets.appendingPathComponent(image.id.uuidString + ".png"), name: image.id.uuidString + "-preview.png")
                    paths[block.id] = (preview, source)
                } else if let audio = block.audio {
                    guard !audio.isDraft else { throw NoteExportError.pending }
                    paths[block.id] = (try add(note.assets.appendingPathComponent(audio.id.uuidString + "." + audio.fileExtension), name: audio.id.uuidString + "-" + filename((audio.name as NSString).deletingPathExtension) + "." + audio.fileExtension), nil)
                } else if let video = block.video {
                    paths[block.id] = (try add(note.assets.appendingPathComponent(video.id.uuidString + "." + video.fileExtension), name: video.id.uuidString + "-" + filename((video.name as NSString).deletingPathExtension) + "." + video.fileExtension), nil)
                } else if let attachment = block.attachment {
                    paths[block.id] = (try add(attachment.url(in: note.assets.appendingPathComponent("files")), name: attachment.id.uuidString + "-" + assetFilename(attachment.name)), nil)
                }
            }
            let text = render(note, format: format, paths: paths)
            result.append(Entry(path: prefix + filename(note.title) + "." + format.fileExtension, data: Data(text.utf8)))
            result += resources
        }
        return result
    }
    static func write(_ notes: [NoteExportSource], format: NoteExportFormat, to destination: URL) throws {
        let access = destination.startAccessingSecurityScopedResource()
        defer { if access { destination.stopAccessingSecurityScopedResource() } }
        let entries = try entries(notes, format: format)
        guard !entries.contains(where: { $0.source?.standardizedFileURL == destination.standardizedFileURL }) else { throw NoteExportError.unavailable }
        let directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let staging = directory.appendingPathComponent("export")
        if isArchive(notes) { try NoteZip.write(entries, to: staging) }
        else { try entries[0].data!.write(to: staging) }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else { try FileManager.default.moveItem(at: staging, to: destination) }
    }
    static func urlPath(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/-._~")))!
    }
    static func html(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func markdown(_ text: String) -> String {
        text.reduce(into: "") { result, character in
            if "\\`*_{}[]<>()#+-.!|~".contains(character) { result += "\\" }
            result.append(character)
        }
    }
    private static func inline(_ block: NoteBlock, format: NoteExportFormat) -> String {
        let text = block.text as NSString
        let orderedMarks = block.marks.sorted { $0.location < $1.location }
        if format == .markdown, zip(orderedMarks, orderedMarks.dropFirst()).allSatisfy({ $0.location + $0.length <= $1.location }) {
            var result = "", position = 0
            for mark in orderedMarks {
                result += markdown(text.substring(with: NSRange(location: position, length: mark.location - position)))
                let raw = text.substring(with: NSRange(location: mark.location, length: mark.length))
                if raw.contains("\n") || raw.first?.isWhitespace == true || raw.last?.isWhitespace == true { break }
                var value = markdown(raw)
                if mark.code {
                    let longest = raw.split(omittingEmptySubsequences: false, whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
                    let fence = String(repeating: "`", count: longest + 1)
                    value = fence + " " + raw + " " + fence
                }
                if mark.bold { value = "**" + value + "**" }
                if mark.italic { value = "_" + value + "_" }
                if mark.strikethrough { value = "~~" + value + "~~" }
                if let link = mark.clickableURL { value = "[" + value + "](<" + link.absoluteString.replacingOccurrences(of: ">", with: "%3E") + ">)" }
                // Separate adjacent formatted spans so their delimiters cannot merge.
                if position == mark.location && position > 0 { result += "<!-- -->" }
                result += value; position = mark.location + mark.length
            }
            if orderedMarks.isEmpty || position == orderedMarks.last.map({ $0.location + $0.length }) {
                result += markdown(text.substring(from: position))
                return result.replacingOccurrences(of: "\n", with: "  \n")
            }
        }
        var boundaries: Set<Int> = [0, text.length]
        for mark in block.marks { boundaries.insert(mark.location); boundaries.insert(mark.location + mark.length) }
        let sorted = boundaries.sorted()
        // HTML spans also work in Markdown and preserve overlapping marks without
        // ambiguous adjacent Markdown delimiters. Plain prose remains Markdown.
        return zip(sorted, sorted.dropFirst()).map { start, end in
            let marks = block.marks.filter { $0.location <= start && $0.location + $0.length >= end }
            let raw = text.substring(with: NSRange(location: start, length: end - start))
            var value = format == .html || !marks.isEmpty ? html(raw) : markdown(raw)
            value = value.replacingOccurrences(of: "\n", with: format == .html || !marks.isEmpty ? "<br>\n" : "  \n")
            if marks.contains(where: \.code) { value = "<code>" + value + "</code>" }
            if marks.contains(where: \.bold) { value = "<strong>" + value + "</strong>" }
            if marks.contains(where: \.italic) { value = "<em>" + value + "</em>" }
            if marks.contains(where: \.strikethrough) { value = "<s>" + value + "</s>" }
            if let url = marks.compactMap(\.clickableURL).first { value = "<a href=\"" + html(url.absoluteString) + "\">" + value + "</a>" }
            return value
        }.joined()
    }
    private static func tableHTML(_ table: NoteTable) -> String {
        "<table>\n" + table.rows.enumerated().map { row, cells in
            "<tr>" + cells.enumerated().map { column, cell in
                let tag = table.isHeader(row: row, column: column) ? "th" : "td"
                return "<\(tag)>" + html(cell).replacingOccurrences(of: "\n", with: "<br>") + "</\(tag)>"
            }.joined() + "</tr>"
        }.joined(separator: "\n") + "\n</table>"
    }
    static func render(_ note: NoteExportSource, format: NoteExportFormat, paths: [UUID: (String, String?)]) -> String {
        var pieces: [String] = []
        var list: String? = nil
        var ordered = 0
        for block in note.document.content.blocks {
            let nextList = block.kind == .orderedList ? "ol" : (block.kind == .bullet || block.kind == .task ? "ul" : nil)
            if format == .html, nextList != list {
                if let list { pieces.append("</\(list)>") }
                if let nextList { pieces.append("<\(nextList)>") }
            }
            if block.kind == .orderedList { ordered = list == "ol" ? ordered + 1 : 1 } else { ordered = 0 }
            list = nextList
            if let (path, original) = paths[block.id] {
                if let image = block.image {
                    var value = format == .html ? "<img src=\"\(path)\" alt=\"\(html(image.name))\">" : "![\(markdown(image.name))](\(path))"
                    if let link = image.clickableLink { value = format == .html ? "<a href=\"\(html(link.absoluteString))\">\(value)</a>" : "[\(value)](<\(link.absoluteString.replacingOccurrences(of: ">", with: "%3E"))>)" }
                    if let caption = image.caption, !caption.isEmpty { value += format == .html ? "<figcaption>\(html(caption))</figcaption>" : "\n\n" + markdown(caption) }
                    if let original { value += format == .html ? "<p><a href=\"\(original)\" download>\(html(image.name))</a></p>" : "\n\n[\(markdown(image.name))](\(original))" }
                    pieces.append(format == .html ? "<figure>\(value)</figure>" : value)
                } else {
                    let name = block.attachment?.name ?? block.audio?.name ?? block.video?.name ?? "Attachment"
                    if format == .markdown { pieces.append("[\(markdown(name))](\(path))") }
                    else {
                        let player = block.audio != nil ? "<audio controls preload=\"metadata\" src=\"\(path)\"></audio>" : block.video != nil ? "<video controls preload=\"metadata\" src=\"\(path)\"></video>" : ""
                        pieces.append("<figure>\(player)<figcaption><a href=\"\(path)\" download>\(html(name))</a></figcaption></figure>")
                    }
                }
            } else if let table = block.table {
                if format == .markdown && table.headerRow && !table.headerColumn {
                    let rows = table.rows.map { "| " + $0.map { markdown($0).replacingOccurrences(of: "\n", with: "<br>") }.joined(separator: " | ") + " |" }
                    pieces.append(([rows[0], "| " + Array(repeating: "---", count: table.columnCount).joined(separator: " | ") + " |"] + Array(rows.dropFirst())).joined(separator: "\n"))
                } else { pieces.append(tableHTML(table)) }
            } else if block.kind == .divider { pieces.append(format == .html ? "<hr>" : "---") }
            else if block.kind == .code {
                if format == .html { pieces.append("<pre><code class=\"language-\(block.language.grammarName)\">\(html(block.text))</code></pre>") }
                else {
                    let longest = block.text.split(omittingEmptySubsequences: false, whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
                    let fence = String(repeating: "`", count: max(3, longest + 1))
                    let language = block.language == .automatic || block.language == .plain ? "" : block.language.grammarName
                    pieces.append(fence + language + "\n" + block.text + "\n" + fence)
                }
            } else {
                let value = inline(block, format: format)
                if format == .html {
                    let tag = block.kind.headingLevel.map { "h\($0)" } ?? (nextList != nil ? "li" : block.kind == .quote ? "blockquote" : "p")
                    let checkbox = block.kind == .task ? "<input type=\"checkbox\" disabled\(block.isChecked ? " checked" : "")> " : ""
                    pieces.append("<\(tag)>\(checkbox)\(value)</\(tag)>")
                } else {
                    let prefix = block.kind.headingLevel.map { String(repeating: "#", count: $0) + " " } ?? (block.kind == .bullet ? "- " : block.kind == .orderedList ? "\(ordered). " : block.kind == .task ? (block.isChecked ? "- [x] " : "- [ ] ") : block.kind == .quote ? "> " : "")
                    pieces.append(prefix + value.replacingOccurrences(of: "\n", with: "\n" + (block.kind == .quote ? "> " : nextList != nil ? "    " : "")))
                }
            }
        }
        if format == .html, let list { pieces.append("</\(list)>") }
        let body = pieces.joined(separator: "\n\n") + "\n"
        guard format == .html else { return body }
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' file: data:; media-src 'self' file:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <title>\(html(note.title))</title>
        <style>body{font:16px/1.65 system-ui,sans-serif;color:#252525;background:#fff;max-width:820px;margin:48px auto;padding:0 28px;overflow-wrap:anywhere}h1,h2,h3,h4{line-height:1.25}pre{background:#f4f5f6;padding:18px;border-radius:10px;overflow:auto;white-space:pre}code{font-family:ui-monospace,monospace}p{min-height:1em}img,video{max-width:100%;height:auto}audio{width:100%}figure{margin:24px 0}figcaption{color:#666;font-size:14px}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ddd;padding:8px;text-align:left}th{background:#f4f5f6}blockquote{border-left:3px solid #ddd;margin-left:0;padding-left:18px;color:#555}a{color:#0868ce}hr{border:0;border-top:1px solid #ddd;margin:24px 0}</style></head><body>
        \(body)</body></html>
        """
    }
}
