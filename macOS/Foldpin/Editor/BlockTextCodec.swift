import AppKit

extension NSAttributedString.Key {
    static let blockID = Self("Foldpin.blockID")
    static let blockKind = Self("Foldpin.blockKind")
    static let blockChecked = Self("Foldpin.checked")
    static let blockLanguage = Self("Foldpin.language")
    static let blockImage = Self("Foldpin.image")
    static let blockFile = Self("Foldpin.file")
    static let blockVideo = Self("Foldpin.video")
    static let blockAudio = Self("Foldpin.audio")
    static let blockTable = Self("Foldpin.table")
    static let blockBoundary = Self("Foldpin.boundary")
    static let nextBlock = Self("Foldpin.nextBlock")
    static let blockMarker = Self("Foldpin.marker")
    static let noteBold = Self("Foldpin.bold")
    static let noteItalic = Self("Foldpin.italic")
    static let noteInlineCode = Self("Foldpin.inlineCode")
    static let noteStrikethrough = Self("Foldpin.strikethrough")
    static let noteLink = Self("Foldpin.link")
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
        if let attachment = block.attachment, let data = try? JSONEncoder().encode(attachment) { values[.blockFile] = data }
        if let video = block.video, let data = try? JSONEncoder().encode(video) { values[.blockVideo] = data }
        if let audio = block.audio, let data = try? JSONEncoder().encode(audio) { values[.blockAudio] = data }
        if let table = block.table, let data = try? JSONEncoder().encode(table) { values[.blockTable] = data }
        return values
    }

    static func prefix(_ block: NoteBlock, ordinal: Int = 1) -> String {
        switch block.kind {
        case .task: block.isChecked ? "☑ " : "☐ "
        case .bullet: "• "
        case .orderedList: "\(ordinal). "
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
            if block.kind == .file, range.length == 1, storage.attribute(.attachment, at: start, effectiveRange: nil) != nil,
               let data = attributes[.blockFile] as? Data, let attachment = try? JSONDecoder().decode(NoteAttachment.self, from: data), attachment.isValid {
                block.attachment = attachment
            } else if block.kind == .video, range.length == 1, storage.attribute(.attachment, at: start, effectiveRange: nil) != nil,
               let data = attributes[.blockVideo] as? Data, let video = try? JSONDecoder().decode(NoteVideo.self, from: data), video.isValid {
                block.video = video
            } else if block.kind == .audio, range.length == 1, storage.attribute(.attachment, at: start, effectiveRange: nil) != nil,
               let data = attributes[.blockAudio] as? Data, let audio = try? JSONDecoder().decode(NoteAudio.self, from: data), audio.isValid {
                block.audio = audio
            } else if block.kind == .divider, range.length == 1, storage.attribute(.attachment, at: start, effectiveRange: nil) != nil {
                block.text = ""
            } else if block.kind == .table, range.length == 1, storage.attribute(.attachment, at: start, effectiveRange: nil) != nil,
                      let data = attributes[.blockTable] as? Data,
                      let table = try? JSONDecoder().decode(NoteTable.self, from: data), table.isValid {
                block.table = table
            } else if block.kind == .image, range.length == 1, storage.attribute(.attachment, at: start, effectiveRange: nil) != nil,
               let data = attributes[.blockImage] as? Data,
               let image = try? JSONDecoder().decode(NoteImage.self, from: data) {
                block.image = image
            } else {
                if block.kind.isAttachment { block.kind = .paragraph }
                let line = string.substring(with: range)
                let numberRange = block.kind == .orderedList ? line.range(of: "^[0-9]+\\. ", options: .regularExpression) : nil
                let marker = block.kind == .orderedList ? numberRange.map { String(line[$0]) } ?? "1. " : prefix(block)
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
                    let link = attrs[.noteLink] as? String
                    let mark = NoteTextMark(location: markRange.location - textRange.location, length: markRange.length,
                        bold: bold, italic: italic, code: attrs[.noteInlineCode] as? Bool ?? false,
                        strikethrough: attrs[.noteStrikethrough] as? Bool ?? false,
                        link: link?.isEmpty == false ? link : nil)
                    guard mark.hasStyle else { return }
                    if let last = block.marks.last, last.location + last.length == mark.location,
                       last.hasSameStyle(as: mark) {
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
                       theme: NativeCodeTheme? = nil, cachedSyntaxOnly: Bool = false, startingOrdinal: Int = 1,
                       tableLayout: ((NoteBlock, CGFloat) -> TableBlockLayout)? = nil,
                       audioModel: ((NoteBlock) -> AudioBlockModel?)? = nil,
                       image: (NoteImage) -> NSImage?) -> NSAttributedString {
        let theme = theme ?? .github
        let result = NSMutableAttributedString(string: "")
        var ordinal = startingOrdinal - 1
        for (index, block) in content.blocks.enumerated() {
            ordinal = block.kind == .orderedList ? ordinal + 1 : 0
            let attributes = style(block, color: color, theme: theme, ordinal: ordinal)
            let marker = prefix(block, ordinal: ordinal)
            let value = NSMutableAttributedString(string: marker + block.text, attributes: attributes)
            let prefixLength = (marker as NSString).length
            if prefixLength > 0 { value.addAttribute(.blockMarker, value: true, range: NSRange(location: 0, length: prefixLength)) }
            for mark in block.marks where mark.location + mark.length <= (block.text as NSString).length {
                let range = NSRange(location: prefixLength + mark.location, length: mark.length)
                value.addAttributes(inlineAttributes(mark, block: block, color: color), range: range)
            }
            if let file = block.attachment {
                let attachment = NSTextAttachment()
                let size = NSSize(width: max(80, width - 2), height: 68)
                attachment.bounds = NSRect(origin: .zero, size: size)
                attachment.image = NSImage(size: size, flipped: true) { rect in
                    let box = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 3), xRadius: 9, yRadius: 9)
                    color.withAlphaComponent(0.045).setFill(); box.fill()
                    color.withAlphaComponent(0.14).setStroke(); box.lineWidth = 1; box.stroke()
                    let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingMiddle
                    let icon = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [color.withAlphaComponent(0.7)]))
                    icon?.draw(in: NSRect(x: 12, y: 20, width: 25, height: 28))
                    (file.name as NSString).draw(in: NSRect(x: 48, y: 13, width: max(20, rect.width - 60), height: 20),
                        withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: color, .paragraphStyle: style])
                    let detail = ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file)
                    (detail as NSString).draw(in: NSRect(x: 48, y: 37, width: max(20, rect.width - 60), height: 17),
                        withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color.withAlphaComponent(0.6)])
                    return true
                }
                value.setAttributedString(NSAttributedString(attachment: attachment))
                value.addAttributes(attributes, range: NSRange(location: 0, length: value.length))
            }
            if let video = block.video {
                let attachment = VideoTextAttachment(video: video, width: max(80, width - 2))
                value.setAttributedString(NSAttributedString(attachment: attachment))
                value.addAttributes(attributes, range: NSRange(location: 0, length: value.length))
            }
            if let audio = block.audio {
                let attachment = AudioTextAttachment(audio: audio, width: max(80, width - 2), model: audioModel?(block))
                value.setAttributedString(NSAttributedString(attachment: attachment))
                value.addAttributes(attributes, range: NSRange(location: 0, length: value.length))
            }
            if let asset = block.image {
                let attachment = NSTextAttachment()
                let layout = ImageBlockLayout(image: asset, availableWidth: width)
                attachment.image = layout.renderedImage(image(asset), asset: asset, ink: color)
                attachment.bounds = NSRect(origin: .zero, size: layout.size)
                value.setAttributedString(NSAttributedString(attachment: attachment))
                value.addAttributes(attributes, range: NSRange(location: 0, length: value.length))
            }
            if block.kind == .divider || block.kind == .table {
                let attachment = NSTextAttachment()
                if let table = block.table {
                    let layout = tableLayout?(block, max(80, width - 2)) ?? TableBlockLayout(table: table, width: max(80, width - 2))
                    attachment.image = layout.image(color: color)
                    attachment.bounds = NSRect(origin: .zero, size: layout.attachmentSize)
                } else {
                    let size = NSSize(width: max(80, width - 2), height: 20)
                    attachment.image = NSImage(size: size, flipped: true) { bounds in
                        NotePalette.rule(for: color).setFill()
                        NSRect(x: 0, y: bounds.midY, width: bounds.width, height: 1).fill()
                        return true
                    }
                    attachment.bounds = NSRect(origin: .zero, size: size)
                }
                value.setAttributedString(NSAttributedString(attachment: attachment))
                value.addAttributes(attributes, range: NSRange(location: 0, length: value.length))
            }
            if block.kind == .code {
                styleCodeParagraphs(value, block: block, color: color, theme: theme)
                highlight(value, language: block.language, theme: theme, cachedOnly: cachedSyntaxOnly)
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

    static func style(_ block: NoteBlock, color: NSColor, theme: NativeCodeTheme? = nil, ordinal: Int = 1) -> [NSAttributedString.Key: Any] {
        let theme = theme ?? .github
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = block.kind == .code ? 0 : 9
        paragraph.lineSpacing = NoteStyleSettings.shared.values.typography.lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        if block.kind == .image { paragraph.alignment = .center }
        paragraph.headIndent = ceil((prefix(block, ordinal: ordinal) as NSString).size(withAttributes: [.font: font(block)]).width)
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
        // Native rich-text insertion fills missing keys from typingAttributes.
        // Explicit neutral marks keep a moved block from inheriting the source
        // caret's bold/italic/strike attributes outside its actual marked runs.
        attrs[.noteBold] = false
        attrs[.noteItalic] = false
        attrs[.noteInlineCode] = false
        attrs[.noteStrikethrough] = false
        attrs[.noteLink] = ""
        attrs[.strikethroughStyle] = 0
        attrs[.font] = font(block)
        attrs[.foregroundColor] = block.kind == .quote || (block.kind == .task && block.isChecked) ? NotePalette.secondaryText(for: color) : color
        attrs[.paragraphStyle] = paragraph
        if block.kind == .code { attrs[.foregroundColor] = theme.foreground }
        if block.kind == .task && block.isChecked { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return attrs
    }

    static func inlineAttributes(_ mark: NoteTextMark, block: NoteBlock, color: NSColor = .labelColor) -> [NSAttributedString.Key: Any] {
        var values: [NSAttributedString.Key: Any] = [
            .noteBold: mark.bold, .noteItalic: mark.italic, .noteInlineCode: mark.code,
            .noteStrikethrough: mark.strikethrough, .noteLink: mark.link ?? "",
            .font: font(block, bold: mark.bold, italic: mark.italic, code: mark.code),
            .strikethroughStyle: mark.strikethrough || (block.kind == .task && block.isChecked) ? NSUnderlineStyle.single.rawValue : 0
        ]
        if mark.code { values[.backgroundColor] = NotePalette.inlineCodeBackground(for: color) }
        if let url = mark.clickableURL { values[.link] = url }
        return values
    }

    private static func styleCodeParagraphs(_ text: NSMutableAttributedString, block: NoteBlock, color: NSColor, theme: NativeCodeTheme) {
        guard text.length > 0, let base = style(block, color: color, theme: theme)[.paragraphStyle] as? NSParagraphStyle else { return }
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

    static func font(_ block: NoteBlock, bold: Bool = false, italic: Bool = false, code: Bool = false) -> NSFont {
        let settings = NoteStyleSettings.shared
        let scale = settings.values.typography.bodySize / 15
        let base: NSFont
        switch block.kind {
        case .heading: base = settings.bodyFont(size: 23 * scale, weight: .semibold)
        case .subheading: base = settings.bodyFont(size: 18 * scale, weight: .semibold)
        case .heading3: base = settings.bodyFont(size: 16 * scale, weight: .semibold)
        case .heading4: base = settings.bodyFont(size: 15 * scale, weight: .semibold)
        case .code: base = settings.codeFont()
        default: base = settings.bodyFont()
        }
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        let face = code ? settings.codeFont(size: base.pointSize) : base
        return traits.isEmpty ? face : NSFontManager.shared.convert(face, toHaveTrait: traits)
    }

    static func highlight(_ text: NSMutableAttributedString, language: CodeLanguage,
                          theme: NativeCodeTheme? = nil, cachedOnly: Bool = false) {
        let engine = CodeSyntaxEngine.shared
        let analysis = cachedOnly ? engine.cached(text.string, language: language)
            : engine.analyzeSynchronously(text.string, language: language)
        guard let analysis else { return }
        let theme = theme ?? .github
        var pending: (token: CodeToken, language: CodeLanguage, range: NSRange)?
        for span in analysis.spans {
            guard let token = CodeToken(highlightScope: span.scope, language: span.language) else { continue }
            if let last = pending, last.token == token, last.language == span.language,
               NSMaxRange(last.range) == span.range.location {
                pending?.range.length += span.range.length
            } else {
                if let last = pending { applyToken(last.token, to: text, range: last.range, language: last.language, theme: theme) }
                pending = (token, span.language, span.range)
            }
        }
        if let last = pending { applyToken(last.token, to: text, range: last.range, language: last.language, theme: theme) }
    }

    static func applyToken(_ token: CodeToken, to text: NSMutableAttributedString, range: NSRange,
                           language: CodeLanguage, theme: NativeCodeTheme) {
        guard range.length > 0 else { return }
        text.addAttributes(theme.attributes(for: token, language: language), range: range)
    }
}
