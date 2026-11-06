import Foundation

nonisolated enum LinkCardConversion {
    struct Target: Equatable, Sendable {
        let source: NoteBlock
        let range: NSRange
        let url: String
        var label: String { (source.text as NSString).substring(with: range) }
    }

    /// Resolve an explicit link or a bare web address. Adjacent formatting runs
    /// belong to the same link, even when part of its label is bold or italic.
    static func target(in block: NoteBlock, selection: NSRange? = nil) -> Target? {
        guard !block.kind.isAttachment, block.kind != .code else { return nil }
        let recognized = PastedWebLinks.recognizing(in: block)
        var links: [Target] = []
        for mark in recognized.marks.sorted(by: { $0.location < $1.location }) {
            guard !mark.code, let link = mark.link, let url = RemoteImageReference.downloadURL(link),
                  mark.location >= 0, mark.length > 0,
                  mark.location <= block.text.utf16.count, mark.length <= block.text.utf16.count - mark.location else { continue }
            if let last = links.last, last.url == url.absoluteString, NSMaxRange(last.range) == mark.location {
                links[links.count - 1] = Target(source: block,
                    range: NSRange(location: last.range.location, length: last.range.length + mark.length), url: last.url)
            } else {
                links.append(Target(source: block, range: NSRange(location: mark.location, length: mark.length), url: url.absoluteString))
            }
        }
        if let selection, selection.location != NSNotFound, selection.location >= 0,
           selection.location <= block.text.utf16.count, selection.length <= block.text.utf16.count - selection.location {
            let matches = links.filter {
                if selection.length == 0 { return NSLocationInRange(selection.location, $0.range) }
                return selection.location >= $0.range.location && NSMaxRange(selection) <= NSMaxRange($0.range)
            }
            if matches.count == 1 { return matches[0] }
            // A caret at the end of a link is common after typing/pasting it.
            if selection.length == 0, let last = links.first(where: { NSMaxRange($0.range) == selection.location }) { return last }
        }
        // A block menu can unambiguously convert a single link. With several
        // links, require the pointer/caret to identify one instead of guessing.
        return links.count == 1 ? links[0] : nil
    }
}
