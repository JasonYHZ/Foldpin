import Foundation

/// A slash command belongs to one caret position and a snapshot of its block.
/// Keeping the snapshot also makes delayed image insertion safe to cancel.
struct SlashCommandContext: Equatable {
    let source: NoteBlock
    let slashOffset: Int

    init?(block: NoteBlock, caretOffset: Int) {
        let text = block.text as NSString
        guard block.kind != .code, !block.kind.isAttachment,
              caretOffset > 0, caretOffset <= text.length,
              text.character(at: caretOffset - 1) == 0x2F else { return nil }
        let offset = caretOffset - 1
        if offset > 0 {
            let previous = text.character(at: offset - 1)
            guard previous == 0x20 || previous == 0x3000 else { return nil }
        }
        source = block
        slashOffset = offset
    }

    /// Consume only the command slash. Earlier text stays in its original
    /// block; following text moves into the new text block (or after media).
    func inserting(_ block: NoteBlock, in content: NoteContent)
        -> (content: NoteContent, index: Int, focusIndex: Int)? {
        guard let sourceIndex = content.blocks.firstIndex(where: { $0.id == source.id }),
              content.blocks[sourceIndex] == source else { return nil }
        let text = source.text as NSString
        let suffixRange = NSRange(location: slashOffset + 1, length: text.length - slashOffset - 1)
        var replacement: [NoteBlock] = []
        if slashOffset > 0 {
            var prefix = source
            prefix.text = text.substring(to: slashOffset)
            prefix.marks = marks(in: NSRange(location: 0, length: slashOffset))
            replacement.append(prefix)
        }
        var inserted = block
        if replacement.isEmpty { inserted.id = source.id }
        let insertionIndex = sourceIndex + replacement.count
        if !inserted.kind.isAttachment {
            inserted.text = text.substring(with: suffixRange)
            inserted.marks = inserted.kind == .code ? [] : marks(in: suffixRange)
        }
        replacement.append(inserted)
        if inserted.kind.isAttachment, suffixRange.length > 0 {
            replacement.append(NoteBlock(text: text.substring(with: suffixRange), marks: marks(in: suffixRange)))
        }
        var next = content
        next.blocks.replaceSubrange(sourceIndex...sourceIndex, with: replacement)
        if inserted.kind.isAttachment, insertionIndex == next.blocks.count - 1 {
            next.blocks.append(NoteBlock())
        }
        let focusIndex = inserted.kind.isAttachment && inserted.kind != .table ? insertionIndex + 1 : insertionIndex
        return (next, insertionIndex, focusIndex)
    }

    private func marks(in range: NSRange) -> [NoteTextMark] {
        source.marks.compactMap { $0.clipped(to: range) }
    }
}
