import Foundation

/// Website metadata is a saved snapshot. Opening a paper never needs the network.
nonisolated struct NoteLinkPreview: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case pending, loaded, unavailable }
    var url: String
    var title: String = ""
    var summary: String = ""
    var siteName: String = ""
    var state: State = .pending
    var imageURL: String?
    var thumbnail: Data?
    var textLabel: String?

    var destination: URL? { RemoteImageReference.downloadURL(url) }
    var host: String { destination?.host ?? url }
    var displayTitle: String { title.isEmpty ? host : title }
    var isValid: Bool {
        destination != nil && title.utf8.count <= 4096 && summary.utf8.count <= 8192 && siteName.utf8.count <= 1024
            && (imageURL.map { RemoteImageReference.downloadURL($0) != nil } ?? true)
            && (textLabel.map { $0.utf8.count <= 131_072 && !$0.contains("\n") } ?? true)
            && (thumbnail.map { LinkPreviewThumbnail.isValid($0) } ?? true)
    }
}

nonisolated enum PastedWebLinks {
    static func standalone(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace) else { return nil }
        return RemoteImageReference.downloadURL(trimmed)
    }

    /// Preserve formatting and explicit Markdown destinations; skip inline code.
    static func recognizing(in block: NoteBlock) -> NoteBlock {
        guard !block.kind.isAttachment, block.kind != .code, block.text.utf16.count <= 131_072,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return block }
        var result = block
        let length = block.text.utf16.count
        for match in detector.matches(in: block.text, range: NSRange(location: 0, length: length)) {
            guard let url = match.url, RemoteImageReference.downloadURL(url.absoluteString) != nil,
                  !block.marks.contains(where: { ($0.code || $0.link != nil) && NSIntersectionRange(NSRange(location: $0.location, length: $0.length), match.range).length > 0 }) else { continue }
            // Overlay the link on each existing style run so the disk model
            // does not contain ambiguous, overlapping marks.
            var boundaries = Set([0, length, match.range.location, NSMaxRange(match.range)])
            for mark in result.marks { boundaries.insert(mark.location); boundaries.insert(mark.location + mark.length) }
            let sorted = boundaries.sorted()
            let old = result.marks
            result.marks = zip(sorted, sorted.dropFirst()).compactMap { start, end in
                var mark = old.first { $0.location <= start && $0.location + $0.length >= end }
                    ?? NoteTextMark(location: start, length: end - start)
                mark.location = start; mark.length = end - start
                if start >= match.range.location && end <= NSMaxRange(match.range) { mark.link = url.absoluteString }
                return mark.hasStyle ? mark : nil
            }
        }
        return result
    }
}
