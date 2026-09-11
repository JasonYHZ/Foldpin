import Foundation

/// Converts only explicit text links, retaining the surrounding block and marks.
/// Bounded, on paste or explicit action; never run while drawing or loading notes.
enum MarkdownTextLinks {
    struct Conversion {
        let block: NoteBlock
        let removed: [NSRange]
        func offset(_ old: Int) -> Int {
            old - removed.reduce(0) { $0 + max(0, min(old, NSMaxRange($1)) - $1.location) }
        }
    }
    private static let starts = try! NSRegularExpression(pattern: #"(?<!!)\[([^\[\]\r\n\x{2028}]+)\](\\?)\("#)

    static func render(_ original: NoteBlock) -> Conversion? {
        guard !original.kind.isAttachment, original.kind != .code, original.text.contains("]"),
              original.text.utf16.count <= 131072 else { return nil }
        let source = original.text as NSString, units = Array(original.text.utf16)
        let candidates = starts.matches(in: original.text, range: NSRange(location: 0, length: source.length))
        var cuts: [NSRange] = [], links: [(NSRange, String)] = [], cursor = 0
        // A code span must stay literal, including in an older unparsed paragraph.
        var codeRanges: [NSRange] = [], codeStart: Int?, ticks = 0, i = 0
        while i < units.count {
            if units[i] == 96 {
                var end = i + 1
                while end < units.count && units[end] == 96 { end += 1 }
                if let start = codeStart, end - i == ticks {
                    codeRanges.append(NSRange(location: start, length: end - start)); codeStart = nil
                } else if codeStart == nil { codeStart = i; ticks = end - i }
                i = end
            } else { i += 1 }
        }
        if let codeStart { codeRanges.append(NSRange(location: codeStart, length: source.length - codeStart)) }
        for match in candidates.prefix(512) {
            let start = match.range.location, label = match.range(at: 1)
            guard start >= cursor, start == 0 || units[start - 1] != 92 else { continue }
            let escaped = match.range(at: 2).length > 0
            let urlStart = NSMaxRange(match.range), limit = min(source.length, urlStart + 8192)
            var end = urlStart, depth = 1
            while end < limit {
                if units[end] == 92, end + 1 < limit {
                    if escaped && units[end + 1] == 41 && depth == 1 { end += 1; depth = 0; break }
                    end += 2; continue
                }
                if units[end] == 40 { depth += 1 }
                if units[end] == 41 { depth -= 1; if depth == 0 { break } }
                end += 1
            }
            guard depth == 0 else { continue }
            let full = NSRange(location: start, length: end + 1 - start)
            guard !codeRanges.contains(where: { NSIntersectionRange($0, full).length > 0 }),
                  !original.marks.contains(where: { ($0.code && NSIntersectionRange(NSRange(location: $0.location, length: $0.length), full).length > 0) || ($0.link != nil && NSIntersectionRange(NSRange(location: $0.location, length: $0.length), label).length > 0) }) else { continue }
            let urlEnd = escaped && end > urlStart && units[end - 1] == 92 ? end - 1 : end
            let destination = source.substring(with: NSRange(location: urlStart, length: urlEnd - urlStart))
            guard let parsed = try? AttributedString(markdown: "[link](" + destination + ")"),
                  let raw = parsed.runs.compactMap(\.link).first?.absoluteString,
                  let url = RemoteImageReference.linkURL(raw) else { continue }
            cuts.append(NSRange(location: start, length: label.location - start))
            cuts.append(NSRange(location: NSMaxRange(label), length: end + 1 - NSMaxRange(label)))
            links.append((label, url.absoluteString)); cursor = end + 1
        }
        guard !links.isEmpty else { return nil }
        var result = original; result.text = ""; result.marks = []
        var sourceCursor = 0
        func append(_ range: NSRange) {
            guard range.length > 0 else { return }
            let offset = result.text.utf16.count
            result.text += source.substring(with: range)
            for mark in original.marks {
                if var clipped = mark.clipped(to: range) { clipped.location += offset; result.marks.append(clipped) }
            }
        }
        for cut in cuts {
            append(NSRange(location: sourceCursor, length: cut.location - sourceCursor))
            sourceCursor = NSMaxRange(cut)
        }
        append(NSRange(location: sourceCursor, length: source.length - sourceCursor))
        let mapping = Conversion(block: result, removed: cuts)
        // Split at style boundaries so adding a link never clears bold/italic.
        let originalMarks = result.marks
        let mappedLinks = links.map { (NSRange(location: mapping.offset($0.0.location), length: $0.0.length), $0.1) }
        var boundaries: Set<Int> = [0, result.text.utf16.count]
        for mark in originalMarks { boundaries.insert(mark.location); boundaries.insert(mark.location + mark.length) }
        for (range, _) in mappedLinks { boundaries.insert(range.location); boundaries.insert(NSMaxRange(range)) }
        let sorted = boundaries.sorted(); result.marks = []
        for (start, end) in zip(sorted, sorted.dropFirst()) where end > start {
            var mark = NoteTextMark(location: start, length: end - start)
            for existing in originalMarks where start >= existing.location && start < existing.location + existing.length {
                mark.bold = mark.bold || existing.bold; mark.italic = mark.italic || existing.italic
                mark.code = mark.code || existing.code; mark.strikethrough = mark.strikethrough || existing.strikethrough
                mark.link = existing.link ?? mark.link
            }
            if let link = mappedLinks.first(where: { NSLocationInRange(start, $0.0) }) { mark.link = link.1 }
            if mark.hasStyle { result.marks.append(mark) }
        }
        return Conversion(block: result, removed: cuts)
    }
}
