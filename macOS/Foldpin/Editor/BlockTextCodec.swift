import AppKit

extension NSAttributedString.Key {
    static let blockID = Self("Foldpin.blockID")
    static let blockKind = Self("Foldpin.blockKind")
    static let blockChecked = Self("Foldpin.checked")
    static let blockLanguage = Self("Foldpin.language")
    static let blockImage = Self("Foldpin.image")
    static let blockBoundary = Self("Foldpin.boundary")
    static let nextBlock = Self("Foldpin.nextBlock")
    static let blockMarker = Self("Foldpin.marker")
    static let noteBold = Self("Foldpin.bold")
    static let noteItalic = Self("Foldpin.italic")
}

struct NoteBlockSpan {
    var block: NoteBlock
    var range: NSRange
    var textRange: NSRange
}

/// The NSTextStorage is an editing surface, while NoteContent is the on-disk
/// schema. Metadata travels with native selection, edits and undo operations.
@MainActor
enum BlockTextCodec {
    static func metadata(_ block: NoteBlock) -> [NSAttributedString.Key: Any] {
        var values: [NSAttributedString.Key: Any] = [
            .blockID: block.id.uuidString, .blockKind: block.kind.rawValue,
            .blockChecked: block.isChecked, .blockLanguage: block.language.rawValue
        ]
        if let image = block.image, let data = try? JSONEncoder().encode(image) { values[.blockImage] = data }
        return values
    }

    static func prefix(_ block: NoteBlock) -> String {
        switch block.kind {
        case .task: block.isChecked ? "☑ " : "☐ "
        case .bullet: "• "
        default: ""
        }
    }

    static func read(_ storage: NSAttributedString, typing: [NSAttributedString.Key: Any]) -> [NoteBlockSpan] {
        let string = storage.string as NSString
        var spans: [NoteBlockSpan] = []
        var start = 0
        var previousBoundary = true
        var seen = Set<UUID>()
        while start <= string.length {
            let newline = string.range(of: "\n", range: NSRange(location: start, length: string.length - start))
            let end = newline.location == NSNotFound ? string.length : newline.location
            let range = NSRange(location: start, length: end - start)
            var attributes = start < storage.length ? storage.attributes(at: start, effectiveRange: nil) : typing
            if start == storage.length, storage.length > 0, string.substring(from: storage.length - 1) == "\n" {
                let separator = storage.attributes(at: storage.length - 1, effectiveRange: nil)
                if separator[.blockBoundary] as? Bool == true,
                   let next = separator[.nextBlock] as? [NSAttributedString.Key: Any] {
                    attributes = next
                } else if separator[.blockKind] as? String == NoteBlockKind.code.rawValue,
                          separator[.blockBoundary] as? Bool != true { attributes = separator }
            }
            var block = NoteBlock()
            block.id = (attributes[.blockID] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            block.kind = (attributes[.blockKind] as? String).flatMap(NoteBlockKind.init(rawValue:)) ?? .paragraph
            block.isChecked = attributes[.blockChecked] as? Bool ?? false
            block.language = (attributes[.blockLanguage] as? String).flatMap(CodeLanguage.init(rawValue:)) ?? .plain
            var textRange = range
            if block.kind == .image, range.length == 1, storage.attribute(.attachment, at: start, effectiveRange: nil) != nil,
               let data = attributes[.blockImage] as? Data,
               let image = try? JSONDecoder().decode(NoteImage.self, from: data) {
                block.image = image
            } else {
                if block.kind == .image { block.kind = .paragraph }
                let marker = prefix(block)
                if !marker.isEmpty {
                    if string.substring(with: range).hasPrefix(marker) {
                        let count = (marker as NSString).length
                        textRange = NSRange(location: start + count, length: range.length - count)
                    } else {
                        block.kind = .paragraph
                    }
                }
                block.text = string.substring(with: textRange)
                storage.enumerateAttributes(in: textRange) { attrs, markRange, _ in
                    let bold = attrs[.noteBold] as? Bool ?? false
                    let italic = attrs[.noteItalic] as? Bool ?? false
                    guard bold || italic else { return }
                    let mark = NoteTextMark(location: markRange.location - textRange.location, length: markRange.length,
                                            bold: bold, italic: italic)
                    if let last = block.marks.last, last.location + last.length == mark.location,
                       last.bold == bold, last.italic == italic {
                        block.marks[block.marks.count - 1].length += mark.length
                    } else { block.marks.append(mark) }
                }
            }
            let hasNewline = end < string.length
            let fullRange = NSRange(location: start, length: range.length + (hasNewline ? 1 : 0))
            if block.kind == .code, let last = spans.last, last.block.kind == .code,
               last.block.id == block.id, !previousBoundary {
                let index = spans.count - 1
                spans[index].block.text += "\n" + block.text
                spans[index].block.marks = []
                spans[index].range.length = NSMaxRange(fullRange) - spans[index].range.location
                spans[index].textRange.length = end - spans[index].textRange.location
            } else {
                if seen.contains(block.id) { block.id = UUID() }
                seen.insert(block.id)
                spans.append(NoteBlockSpan(block: block, range: fullRange, textRange: textRange))
            }
            previousBoundary = hasNewline && (storage.attribute(.blockBoundary, at: end, effectiveRange: nil) as? Bool == true)
            if !hasNewline { break }
            start = end + 1
        }
        return spans
    }

    static func render(_ content: NoteContent, color: NSColor, width: CGFloat,
                       image: (NoteImage) -> NSImage?) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for (index, block) in content.blocks.enumerated() {
            let attributes = style(block, color: color)
            let value = NSMutableAttributedString(string: prefix(block) + block.text, attributes: attributes)
            let prefixLength = (prefix(block) as NSString).length
            if prefixLength > 0 { value.addAttribute(.blockMarker, value: true, range: NSRange(location: 0, length: prefixLength)) }
            for mark in block.marks where mark.location + mark.length <= (block.text as NSString).length {
                let range = NSRange(location: prefixLength + mark.location, length: mark.length)
                value.addAttributes([.noteBold: mark.bold, .noteItalic: mark.italic,
                                     .font: font(block, bold: mark.bold, italic: mark.italic)], range: range)
            }
            if let asset = block.image {
                let attachment = NSTextAttachment()
                attachment.image = image(asset) ?? NSImage(systemSymbolName: "photo", accessibilityDescription: asset.name)
                let available = max(80, width)
                let w = min(available, CGFloat(asset.pixelWidth))
                let h = max(24, w * CGFloat(asset.pixelHeight) / CGFloat(asset.pixelWidth))
                attachment.bounds = NSRect(x: 0, y: -4, width: w, height: min(h, 600))
                // Constrain extreme portraits proportionally, without distortion.
                if h > 600 { attachment.bounds.size.width = w * 600 / h }
                value.setAttributedString(NSAttributedString(attachment: attachment))
                value.addAttributes(attributes, range: NSRange(location: 0, length: value.length))
            }
            if block.kind == .code {
                styleCodeParagraphs(value, block: block, color: color)
                highlight(value, language: block.language)
            }
            result.append(value)
            if index < content.blocks.count - 1 {
                var separator = attributes
                separator[.blockBoundary] = true
                separator[.nextBlock] = metadata(content.blocks[index + 1])
                result.append(NSAttributedString(string: "\n", attributes: separator))
            }
        }
        return result
    }

    static func style(_ block: NoteBlock, color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = block.kind == .code ? 0 : 9
        paragraph.lineSpacing = 3
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.headIndent = CGFloat((prefix(block) as NSString).length) * 9
        if block.kind == .quote { paragraph.headIndent = 12; paragraph.firstLineHeadIndent = 12 }
        paragraph.tabStops = []
        paragraph.defaultTabInterval = 28
        if block.kind == .code {
            paragraph.headIndent = 12
            paragraph.firstLineHeadIndent = 12
            paragraph.tailIndent = -12
            if block.text.isEmpty {
                paragraph.paragraphSpacingBefore = 10
                paragraph.paragraphSpacing = 10
            }
        }
        var attrs = metadata(block)
        attrs[.font] = font(block)
        attrs[.foregroundColor] = block.kind == .quote || (block.kind == .task && block.isChecked) ? NSColor.secondaryLabelColor : color
        attrs[.paragraphStyle] = paragraph
        if block.kind == .code { attrs[.foregroundColor] = GitHubCodeTheme.foreground }
        if block.kind == .task && block.isChecked { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return attrs
    }

    private static func styleCodeParagraphs(_ text: NSMutableAttributedString, block: NoteBlock, color: NSColor) {
        guard text.length > 0, let base = style(block, color: color)[.paragraphStyle] as? NSParagraphStyle else { return }
        let source = text.string as NSString
        var start = 0
        while start < source.length {
            let range = source.paragraphRange(for: NSRange(location: start, length: 0))
            let paragraph = base.mutableCopy() as! NSMutableParagraphStyle
            paragraph.paragraphSpacingBefore = start == 0 ? 10 : 0
            paragraph.paragraphSpacing = NSMaxRange(range) == source.length ? 10 : 0
            text.addAttribute(.paragraphStyle, value: paragraph, range: range)
            start = NSMaxRange(range)
        }
    }

    static func font(_ block: NoteBlock, bold: Bool = false, italic: Bool = false) -> NSFont {
        let base: NSFont
        switch block.kind {
        case .heading: base = .systemFont(ofSize: 23, weight: .semibold)
        case .subheading: base = .systemFont(ofSize: 18, weight: .semibold)
        case .code: base = .monospacedSystemFont(ofSize: 13, weight: .regular)
        default: base = .systemFont(ofSize: 15)
        }
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        return traits.isEmpty ? base : NSFontManager.shared.convert(base, toHaveTrait: traits)
    }

    // Bounded lexical highlighting for snippets, not a compiler or code runner.
    // Long blocks stay editable without running regexes over the entire document.
    static func highlight(_ text: NSMutableAttributedString, language: CodeLanguage) {
        guard language != .plain, text.length < 24_000 else { return }
        let keywords: String
        switch language {
        case .swift: keywords = "let|var|func|class|struct|enum|protocol|extension|import|return|if|else|guard|for|in|while|switch|case|break|true|false|nil|try|throw|throws|async|await|private|public|static|self"
        case .javascript, .typescript: keywords = "const|let|var|function|return|if|else|for|of|in|while|class|new|import|export|from|default|async|await|true|false|null|undefined|interface|type|extends"
        case .python: keywords = "def|class|return|if|elif|else|for|in|while|import|from|as|try|except|with|lambda|True|False|None|and|or|not|async|await"
        case .sql: keywords = "(?i:select|from|where|join|on|as|and|or|insert|into|values|update|set|delete|create|table|order|by|group|limit|null|count|distinct|asc|desc)"
        case .shell: keywords = "if|then|else|fi|for|in|do|done|while|case|esac|function|export|echo|exit"
        case .json: keywords = "true|false|null"
        case .plain: return
        }
        let comment: String
        switch language {
        case .python, .shell: comment = "#[^\\n]*"
        case .sql: comment = "--[^\\n]*|/\\*[\\s\\S]*?\\*/"
        case .json: comment = "(?!)"
        default: comment = "//[^\\n]*|/\\*[\\s\\S]*?\\*/"
        }
        let quoted = #""""[\s\S]*?"""|'''[\s\S]*?'''|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'"#
        let strings = [.javascript, .typescript, .shell].contains(language) ? quoted + #"|`(?:\\.|[^`\\])*`"# : quoted
        let rules: [(String, String, NSColor)] = [
            ("comment", comment, GitHubCodeTheme.comment),
            ("string", strings, GitHubCodeTheme.string),
            ("keyword", "\\b(?:" + keywords + ")\\b", GitHubCodeTheme.keyword),
            ("constant", "\\b(?:0[xX][0-9a-fA-F]+|[0-9]+(?:\\.[0-9]+)?)\\b", GitHubCodeTheme.constant),
            ("function", #"\b[A-Za-z_$][\w$]*(?=\s*\()"#, GitHubCodeTheme.function)
        ]
        // One ordered scan keeps comment markers inside strings literal and
        // prevents later rules from recoloring keywords inside comments.
        let pattern = rules.map { "(?<" + $0.0 + ">" + $0.1 + ")" }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        for match in regex.matches(in: text.string, range: NSRange(location: 0, length: text.length)) {
            for (name, _, color) in rules where match.range(withName: name).location != NSNotFound {
                text.addAttribute(.foregroundColor, value: color, range: match.range)
                break
            }
        }
    }
}
