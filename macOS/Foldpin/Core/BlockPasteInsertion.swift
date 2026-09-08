import Foundation

/// Splice parsed blocks at a text selection without dropping either edge of
/// the surrounding document. Offsets address block text, never list markers.
enum BlockPasteInsertion {
    struct Position { let index: Int; let offset: Int }

    static func inserting(_ incoming: NoteContent, into content: NoteContent, from start: Position, to end: Position)
        -> (content: NoteContent, index: Int, offset: Int)? {
        guard content.blocks.indices.contains(start.index), content.blocks.indices.contains(end.index),
              start.index <= end.index, start.index != end.index || start.offset <= end.offset else { return nil }
        let first = content.blocks[start.index], last = content.blocks[end.index]
        let firstLength = length(first), lastLength = length(last)
        guard (0...firstLength).contains(start.offset), (0...lastLength).contains(end.offset) else { return nil }
        let prefix = slice(first, range: NSRange(location: 0, length: start.offset))
        var suffix = slice(last, range: NSRange(location: end.offset, length: lastLength - end.offset))
        if suffix?.id == prefix?.id { suffix?.id = UUID() }
        var inserted = incoming.blocks
        for index in inserted.indices { inserted[index].id = UUID() }
        var replacement: [NoteBlock] = []
        if let prefix {
            if !prefix.kind.isAttachment && inserted[0].kind == .paragraph {
                inserted[0] = joined(prefix, inserted[0])
            } else { replacement.append(prefix) }
        } else if inserted.count == 1 && inserted[0].kind == .paragraph && !first.kind.isAttachment {
            // Inline-only Markdown follows the current heading/list style.
            var empty = first; empty.text = ""; empty.marks = []
            inserted[0] = joined(empty, inserted[0])
        }
        replacement.append(contentsOf: inserted)
        var focusID = replacement.last!.id
        var focusOffset = length(replacement.last!)
        if let suffix {
            let index = replacement.count - 1
            if !suffix.kind.isAttachment && !replacement[index].kind.isAttachment &&
                (replacement[index].kind == .paragraph || incoming.blocks.count == 1 && incoming.blocks[0].kind == .paragraph) {
                replacement[index] = joined(replacement[index], suffix)
            } else {
                replacement.append(suffix)
                if inserted.last!.kind.isAttachment { focusID = suffix.id; focusOffset = 0 }
            }
        } else if inserted.last!.kind.isAttachment {
            let following = NoteBlock()
            replacement.append(following); focusID = following.id; focusOffset = 0
        }
        var result = content
        result.blocks.replaceSubrange(start.index...end.index, with: replacement)
        guard let focusIndex = result.blocks.firstIndex(where: { $0.id == focusID }),
              (try? result.validate()) != nil else { return nil }
        return (result, focusIndex, focusOffset)
    }

    private static func length(_ block: NoteBlock) -> Int { block.kind.isAttachment ? 1 : (block.text as NSString).length }

    private static func slice(_ block: NoteBlock, range: NSRange) -> NoteBlock? {
        guard range.length > 0 else { return nil }
        if block.kind.isAttachment { return block }
        var result = block
        result.text = (block.text as NSString).substring(with: range)
        result.marks = block.marks.compactMap { $0.clipped(to: range) }
        return result
    }

    private static func joined(_ first: NoteBlock, _ second: NoteBlock) -> NoteBlock {
        var result = first
        let offset = (first.text as NSString).length
        result.text += second.text
        result.marks += second.marks.map { var mark = $0; mark.location += offset; return mark }
        return result
    }
}
