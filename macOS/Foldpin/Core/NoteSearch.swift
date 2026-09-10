import Foundation

/// UTF-16 offsets refer to stored text, never generated list markers or assets.
nonisolated enum NoteSearch {
    enum Field: Hashable, Sendable { case text, cell(Int, Int), caption }
    struct Hit: Equatable, Sendable {
        let blockID: UUID
        let field: Field
        let range: NSRange
    }
    struct Result: Sendable {
        var hits: [Hit] = []
        var truncated = false
    }
    static let limit = 50_000
    static func find(in content: NoteContent, query: String, caseSensitive: Bool, cancelled: () -> Bool = { false }) -> Result {
        guard !query.isEmpty else { return Result() }
        var result = Result()
        for block in content.blocks {
            var fields: [(Field, String)] = []
            if ![NoteBlockKind.image, .audio, .video, .table, .divider].contains(block.kind) { fields.append((.text, block.text)) }
            if let table = block.table {
                for (row, cells) in table.rows.enumerated() {
                    for (column, text) in cells.enumerated() { fields.append((.cell(row, column), text)) }
                }
            }
            if let caption = block.image?.caption { fields.append((.caption, caption)) }
            for (field, value) in fields {
                let text = value as NSString
                var offset = 0
                while offset < text.length {
                    if cancelled() { return Result() }
                    let range = text.range(of: query, options: caseSensitive ? [] : [.caseInsensitive], range: NSRange(location: offset, length: text.length - offset))
                    guard range.location != NSNotFound, range.length > 0 else { break }
                    if result.hits.count == limit { result.truncated = true; return result }
                    result.hits.append(Hit(blockID: block.id, field: field, range: range))
                    offset = NSMaxRange(range)
                }
            }
        }
        return result
    }

    /// Assemble replacements from original offsets in one pass per field. Marks
    /// outside matches survive, replacement text inherits the first character.
    static func replacing(_ hits: [Hit], in content: NoteContent, with replacement: String, cancelled: () -> Bool = { false }) -> NoteContent? {
        // Fields are single-line controls; embedded LF is a block delimiter in
        // the native codec. Preserve typed line breaks inside the same block.
        let replacement = replacement.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "\u{2028}")
        var next = content
        let byBlock = Dictionary(grouping: hits, by: \.blockID)
        for index in next.blocks.indices {
            if cancelled() { return nil }
            guard let matches = byBlock[next.blocks[index].id] else { continue }
            let grouped = Dictionary(grouping: matches, by: \.field)
            for (field, matches) in grouped {
                let text: String
                switch field {
                case .text: text = next.blocks[index].text
                case .cell(let row, let column):
                    guard let table = next.blocks[index].table, table.rows.indices.contains(row), table.rows[row].indices.contains(column) else { return nil }
                    text = table.rows[row][column]
                case .caption:
                    guard let caption = next.blocks[index].image?.caption else { return nil }; text = caption
                }
                let ranges = matches.map(\.range).sorted { $0.location < $1.location }
                let source = text as NSString
                let output = NSMutableString(capacity: source.length)
                var cursor = 0
                var deltas: [Int] = []
                let replacementLength = (replacement as NSString).length
                for range in ranges {
                    if cancelled() { return nil }
                    guard range.location >= cursor, range.length > 0, NSMaxRange(range) <= source.length else { return nil }
                    output.append(source.substring(with: NSRange(location: cursor, length: range.location - cursor)))
                    output.append(replacement); cursor = NSMaxRange(range)
                    deltas.append(output.length - cursor)
                }
                output.append(source.substring(from: cursor))
                // Map each mark with two binary searches, avoiding a scan of
                // every mark for every match in heavily formatted documents.
                func mapped(_ offset: Int) -> Int {
                    var low = 0, high = ranges.count
                    while low < high {
                        let mid = (low + high) / 2
                        if ranges[mid].location < offset { low = mid + 1 } else { high = mid }
                    }
                    guard low > 0 else { return offset }
                    let index = low - 1, range = ranges[index]
                    if offset <= NSMaxRange(range) {
                        let before = index == 0 ? 0 : deltas[index - 1]
                        return range.location + before + replacementLength
                    }
                    return offset + deltas[index]
                }
                let marks = (field == .text ? next.blocks[index].marks : []).compactMap { original -> NoteTextMark? in
                    var mark = original
                    mark.location = mapped(original.location)
                    mark.length = mapped(original.location + original.length) - mark.location
                    return mark.length > 0 ? mark : nil
                }
                if field == .caption && output.length > 0 && (output as String).count > 4096 { return nil }
                switch field {
                case .text: next.blocks[index].text = output as String; next.blocks[index].marks = marks.sorted { $0.location < $1.location }
                case .cell(let row, let column): next.blocks[index].table?.rows[row][column] = output as String
                case .caption: next.blocks[index].image?.caption = output as String
                }
            }
        }
        return next
    }
}
