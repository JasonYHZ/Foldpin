import Foundation

/// Foundation parses Markdown; this adapter maps its semantic runs into the
/// block types Foldpin can edit. No HTML view, network access or script engine.
nonisolated enum MarkdownPasteParser {
    private struct Piece {
        var text: String
        let intents: [PresentationIntent.IntentType]
        let inline: InlinePresentationIntent
        let link: URL?
        let image: URL?
        let position: AttributedString.MarkdownSourcePosition?
    }

    private struct Group {
        let identity: Int
        var pieces: [Piece]
        var start: Int?
        var end: Int?
        var intents: [PresentationIntent.IntentType] { pieces[0].intents }
    }

    static func parse(_ source: String, importingRemoteImages: Bool = true) -> NoteContent? {
        // Empty image labels have no source position (and linked ones emit no
        // run at all). A temporary label makes them observable; strip it from
        // every parsed value, including literal code, before building blocks.
        let emptyLabel = "foldpin-empty-image-" + UUID().uuidString
        let parsedSource = source.replacingOccurrences(of: "![]", with: "![" + emptyLabel + "]")
        guard !source.isEmpty,
              let attributed = try? AttributedString(markdown: parsedSource,
                options: .init(allowsExtendedAttributes: false, interpretedSyntax: .full,
                               failurePolicy: .throwError, appliesSourcePositionAttributes: true)) else { return nil }
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        let parsedLines = parsedSource.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        let parsedLineBytes = parsedLines.map { Array($0.utf8) }
        let references = parsedLines.filter { $0.range(of: #"^ {0,3}\[[^\]]+\]:"#, options: .regularExpression) != nil }.joined(separator: "\n")
        func cleanedURL(_ url: URL?) -> URL? {
            url.flatMap { URL(string: $0.absoluteString.replacingOccurrences(of: emptyLabel, with: "")) }
        }
        var groups: [Group] = []
        for run in attributed.runs {
            let intents = run.presentationIntent?.components ?? []
            let table = intents.first { if case .table = $0.kind { return true }; return false }
            let identity = table?.identity ?? intents.first?.identity ?? -(groups.count + 1)
            let piece = Piece(text: String(attributed[run.range].characters).replacingOccurrences(of: emptyLabel, with: ""), intents: intents,
                              inline: run.inlinePresentationIntent ?? [], link: cleanedURL(run.link), image: cleanedURL(run.imageURL ?? linkedImageURL(link: run.link, position: run.markdownSourcePosition, lines: parsedLineBytes, references: references)),
                              position: run.markdownSourcePosition)
            if groups.last?.identity != identity {
                groups.append(Group(identity: identity, pieces: [], start: nil, end: nil))
            }
            let index = groups.count - 1
            groups[index].pieces.append(piece)
            if let position = piece.position {
                groups[index].start = min(groups[index].start ?? Int.max, position.startLine - 1)
                groups[index].end = max(groups[index].end ?? 0, position.endLine - 1)
            }
        }

        var blocks: [NoteBlock] = []
        var cursor = 0
        var formatted = false
        for index in groups.indices {
            var group = groups[index]
            // Foundation gives thematic breaks a display character but no
            // source position. Locate its rule between the neighboring groups.
            if group.start == nil, group.intents.contains(where: { $0.kind == .thematicBreak }) {
                let limit = groups.dropFirst(index + 1).compactMap(\.start).first ?? lines.count
                guard cursor < limit, let line = (cursor..<limit).first(where: { isRule(lines[$0]) }) else { return nil }
                group.start = line; group.end = line
            }
            guard var start = group.start, var end = group.end,
                  start >= cursor, start < lines.count, end >= start, end < lines.count else { return nil }
            if group.intents.contains(where: { if case .table = $0.kind { return true }; return false }) {
                // Empty cells/rows have no attributed runs. Recover their table
                // extent from the source so they keep their rows and columns.
                while start > cursor && lines[start - 1].contains("|") { start -= 1 }
                end = max(end, min(lines.count - 1, start + 1))
                while end + 1 < lines.count && lines[end + 1].contains("|") && !lines[end + 1].trimmingCharacters(in: .whitespaces).isEmpty { end += 1 }
            } else if group.intents.contains(where: { if case .header = $0.kind { return true }; return false }),
                      end + 1 < lines.count, isSetextUnderline(lines[end + 1]) {
                end += 1
            }
            appendUnrepresented(lines: lines, range: cursor..<start, to: &blocks, formatted: &formatted)
            let raw = lines[start...end].joined(separator: "\u{2028}")
            if importingRemoteImages, let images = remoteBlocks(group) {
                blocks.append(contentsOf: images); formatted = true
            } else if let block = convert(group, sourceLines: Array(lines[start...end])) {
                blocks.append(block)
                formatted = formatted || block.kind != .paragraph || !block.marks.isEmpty
            } else { blocks.append(NoteBlock(text: raw)) }
            cursor = end + 1
        }
        appendUnrepresented(lines: lines, range: cursor..<lines.count, to: &blocks, formatted: &formatted)
        let result = NoteContent(blocks: blocks)
        guard formatted, (try? result.validate()) != nil else { return nil }
        return result
    }

    // Foundation emits only `.link` for an image wrapped in a link. Its
    // source position still spans the inner image syntax: parse that fragment
    // independently to recover the image without rewriting the user's source.
    private static func linkedImageURL(link: URL?, position: AttributedString.MarkdownSourcePosition?, lines: [[UInt8]], references: String) -> URL? {
        guard link != nil, let position,
              lines.indices.contains(position.startLine - 1), lines.indices.contains(position.endLine - 1),
              position.endLine >= position.startLine else { return nil }
        var bytes: [UInt8] = []
        for line in (position.startLine - 1)...(position.endLine - 1) {
            let start = line == position.startLine - 1 ? position.startColumn - 1 : 0
            let end = line == position.endLine - 1 ? min(lines[line].count, position.endColumn) : lines[line].count
            guard start >= 0, end >= start, end <= lines[line].count else { return nil }
            if !bytes.isEmpty { bytes.append(10) }
            bytes.append(contentsOf: lines[line][start..<end])
        }
        guard let fragment = String(bytes: bytes, encoding: .utf8), fragment.hasPrefix("!["),
              let parsed = try? AttributedString(markdown: fragment + "\n\n" + references) else { return nil }
        return parsed.runs.compactMap(\.imageURL).first
    }

    private static func remoteBlocks(_ group: Group) -> [NoteBlock]? {
        guard group.pieces.contains(where: { $0.image != nil }),
              !group.pieces.contains(where: { $0.inline.contains(.inlineHTML) || $0.inline.contains(.blockHTML) }),
              !group.intents.contains(where: { if case .table = $0.kind { return true }; return false }),
              group.pieces.allSatisfy({ $0.image.map { RemoteImageReference.downloadURL($0.absoluteString) != nil } ?? true }) else { return nil }
        var result: [NoteBlock] = [], textPieces: [Piece] = []
        func flushText() {
            guard !textPieces.isEmpty else { return }
            var textGroup = group; textGroup.pieces = textPieces
            if let block = convert(textGroup, sourceLines: []), !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(block)
            }
            textPieces.removeAll(keepingCapacity: true)
        }
        for piece in group.pieces {
            guard let url = piece.image else { textPieces.append(piece); continue }
            flushText()
            let name = piece.text.isEmpty ? url.lastPathComponent : piece.text
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "]", with: "\\]")
            var markdown = "![" + escaped + "](<" + url.absoluteString + ">)"
            if let link = piece.link { markdown = "[" + markdown + "](<" + link.absoluteString + ">)" }
            var image = NoteImage(id: UUID(), name: name, pixelWidth: 260, pixelHeight: 64)
            image.remoteSource = url.absoluteString; image.remoteState = .pending
            image.sourceMarkdown = markdown; image.link = piece.link?.absoluteString
            result.append(NoteBlock(kind: .image, image: image))
        }
        flushText()
        return result
    }

    private static func convert(_ group: Group, sourceLines: [String]) -> NoteBlock? {
        // Unsupported structures stay literal, including their URLs and source
        // indentation. A rendered alt label must never discard an image URL.
        guard !group.pieces.contains(where: { $0.image != nil || $0.inline.contains(.inlineHTML) || $0.inline.contains(.blockHTML) }),
              group.intents.filter({ if case .listItem = $0.kind { return true }; return false }).count <= 1 else { return nil }
        let intents = group.intents
        if let table = intents.first(where: { if case .table = $0.kind { return true }; return false }),
           case .table(let columns) = table.kind {
            guard !columns.isEmpty, sourceLines.count >= 2 else { return nil }
            var rows = Array(repeating: Array(repeating: "", count: columns.count), count: sourceLines.count - 1)
            for piece in group.pieces {
                var row = 0
                var column: Int?
                for intent in piece.intents {
                    if case .tableRow(let index) = intent.kind { row = index }
                    if case .tableCell(let index) = intent.kind { column = index }
                }
                guard let column, rows.indices.contains(row), rows[row].indices.contains(column) else { return nil }
                // Cells currently store plain strings. Keep link destinations
                // visible until cell rich text becomes part of the data model.
                rows[row][column] += piece.text
                if let link = piece.link { rows[row][column] += " (\(link.absoluteString))" }
            }
            return NoteBlock(kind: .table, table: NoteTable(rows: rows))
        }
        if intents.contains(where: { $0.kind == .thematicBreak }) { return NoteBlock(kind: .divider) }
        if let code = intents.first(where: { if case .codeBlock = $0.kind { return true }; return false }),
           case .codeBlock(let hint) = code.kind {
            return NoteBlock(kind: .code, text: group.pieces.map(\.text).joined(), language: language(hint))
        }
        var block = NoteBlock()
        var hasUnsupportedLink = false
        if let heading = intents.first(where: { if case .header = $0.kind { return true }; return false }),
           case .header(let level) = heading.kind {
            guard (1...4).contains(level) else { return nil }
            block.kind = [.heading, .subheading, .heading3, .heading4][level - 1]
        } else if intents.contains(where: { $0.kind == .orderedList }) { block.kind = .orderedList }
        else if intents.contains(where: { $0.kind == .unorderedList }) { block.kind = .bullet }
        else if intents.contains(where: { $0.kind == .blockQuote }) { block.kind = .quote }
        for piece in group.pieces {
            var text = piece.inline.contains(.softBreak) || piece.inline.contains(.lineBreak)
                ? "\u{2028}" : piece.text.replacingOccurrences(of: "\n", with: "\u{2028}")
            var mark = NoteTextMark(location: (block.text as NSString).length, length: (text as NSString).length,
                bold: piece.inline.contains(.stronglyEmphasized), italic: piece.inline.contains(.emphasized),
                code: piece.inline.contains(.code), strikethrough: piece.inline.contains(.strikethrough),
                link: piece.link?.absoluteString)
            if let link = piece.link, mark.clickableURL == nil {
                // A relative/unsupported link must not make valid neighboring
                // links lose their rendering. Keep this destination as text.
                hasUnsupportedLink = true
                text = "[" + text + "](" + link.absoluteString + ")"
                mark.link = nil; mark.length = text.utf16.count
            }
            block.text += text
            if mark.hasStyle && mark.length > 0 { block.marks.append(mark) }
        }
        if block.kind == .bullet, let prefix = block.text.range(of: "^\\[[ xX]\\][ \\t]+", options: .regularExpression) {
            let length = (String(block.text[prefix]) as NSString).length
            block.isChecked = block.text.hasPrefix("[x]") || block.text.hasPrefix("[X]")
            block.kind = .task
            let range = NSRange(location: length, length: (block.text as NSString).length - length)
            block.marks = block.marks.compactMap { $0.clipped(to: range) }
            block.text = (block.text as NSString).substring(from: length)
        }
        let rendered = MarkdownTextLinks.render(block)?.block ?? block
        if hasUnsupportedLink, !rendered.marks.contains(where: { $0.clickableURL != nil }) { return nil }
        return rendered
    }

    private static func language(_ hint: String?) -> CodeLanguage {
        let name = hint?.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return MarkdownBlockShortcut.match(prefix: "```" + name, trigger: .newline)?.language ?? .automatic
    }

    private static func isRule(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespaces).filter { $0 != " " && $0 != "\t" }
        return value.count >= 3 && ["-", "*", "_"].contains(value.first.map(String.init) ?? "") && Set(value).count == 1
    }

    private static func isSetextUnderline(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespaces)
        return !value.isEmpty && Set(value).count == 1 && (value.first == "=" || value.first == "-")
    }

    /// Empty semantic blocks are omitted by Foundation. Keep unrepresented
    /// source instead of silently deleting it; recover simple empty headings
    /// and empty fences, and preserve unknown constructs as literal paragraphs.
    private static func appendUnrepresented(lines: [String], range: Range<Int>, to blocks: inout [NoteBlock], formatted: inout Bool) {
        var index = range.lowerBound
        while index < range.upperBound {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let shortcut = MarkdownBlockShortcut.match(prefix: line, trigger: .space), shortcut.kind.headingLevel != nil {
                blocks.append(NoteBlock(kind: shortcut.kind)); formatted = true
            } else if (line.hasPrefix("```") || line.hasPrefix("~~~")), index + 1 < range.upperBound,
                      lines[index + 1].trimmingCharacters(in: .whitespaces) == String(line.prefix(3)) {
                blocks.append(NoteBlock(kind: .code, language: language(String(line.dropFirst(3)))))
                formatted = true; index += 1
            } else if !line.isEmpty { blocks.append(NoteBlock(text: raw)) }
            index += 1
        }
    }
}
