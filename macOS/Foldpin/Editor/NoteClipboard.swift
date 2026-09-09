import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Portable rich text plus Foldpin's lossless block representation. Build all
/// payloads before replacing the clipboard; never change the editor selection.
@MainActor
enum NoteClipboard {
    static let blocksType = NSPasteboard.PasteboardType("dev.jasonyu.foldpin.blocks.v1")

    static func copyImage(_ image: NoteImage, file: NoteFile, to board: NSPasteboard = .general) throws {
        let item = try imageItem(image, file: file)
        board.clearContents()
        guard board.writeObjects([item]) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Only image formats: receiving apps must not choose a filename or a
    /// Foldpin JSON reference instead. Use the original resolution if available.
    static func imageItem(_ image: NoteImage, file: NoteFile) throws -> NSPasteboardItem {
        var source: CGImageSource?
        for original in [true, false] {
            if let data = try? Data(contentsOf: file.imageURL(image.id, original: original)),
               let candidate = CGImageSourceCreateWithData(data as CFData, nil),
               CGImageSourceGetCount(candidate) > 0 {
                source = candidate
                break
            }
        }
        guard let source,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 80_000_000,
              let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height)
              ] as CFDictionary) else { throw NoteFileError.missingImage }
        let item = NSPasteboardItem()
        for (type, identifier) in [(NSPasteboard.PasteboardType.png, UTType.png.identifier), (.tiff, UTType.tiff.identifier)] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, identifier as CFString, 1, nil) else {
                throw NoteFileError.missingImage
            }
            CGImageDestinationAddImage(destination, bitmap, nil)
            guard CGImageDestinationFinalize(destination) else { throw NoteFileError.missingImage }
            item.setData(data as Data, forType: type)
        }
        return item
    }

    static func copy(_ content: NoteContent, file: NoteFile, to board: NSPasteboard = .general) throws {
        try content.validate()
        var audioData: [UUID: Data] = [:]
        var audioBytes = 0
        for audio in content.blocks.compactMap(\.audio) where audioData[audio.id] == nil {
            let url = file.audioURL(audio)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            // Rich clipboard formats make multiple encoded copies. Export large
            // recordings separately instead of allocating unbounded clipboard data.
            guard !audio.isDraft, size <= 32 * 1024 * 1024 - audioBytes else { throw NoteAudioCopyError(message: String(localized: "Finish the recording before copying. For audio over 32 MB, use Export Audio instead.", bundle: LanguageSettings.shared.bundle)) }
            let data = try Data(contentsOf: url)
            audioBytes += data.count; audioData[audio.id] = data
        }
        var imageData: [UUID: Data] = [:]
        for block in content.blocks {
            guard let image = block.image else { continue }
            let data = try Data(contentsOf: file.imageURL(image.id))
            guard NSImage(data: data) != nil else { throw NoteFileError.missingImage }
            imageData[image.id] = data
        }
        let rendered = NSMutableAttributedString(attributedString: BlockTextCodec.render(
            content, color: .black, width: 640, theme: .github, cachedSyntaxOnly: true,
            image: { imageData[$0.id].flatMap(NSImage.init(data:)) }))
        let fullRange = NSRange(location: 0, length: rendered.length)
        rendered.enumerateAttribute(.attachment, in: fullRange) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            if let metadata = rendered.attribute(.blockAudio, at: range.location, effectiveRange: nil) as? Data,
               let audio = try? JSONDecoder().decode(NoteAudio.self, from: metadata), let data = audioData[audio.id] {
                let wrapper = FileWrapper(regularFileWithContents: data)
                wrapper.preferredFilename = "audio-\(audio.id).\(audio.fileExtension)"
                rendered.addAttribute(.attachment, value: NSTextAttachment(fileWrapper: wrapper), range: range)
                return
            }
            guard let png = attachment.image.flatMap({ image -> Data? in
                      guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
                      return bitmap.representation(using: .png, properties: [:])
                  }) else { return }
            let wrapper = FileWrapper(regularFileWithContents: png)
            wrapper.preferredFilename = "attachment-\(range.location).png"
            let portable = NSTextAttachment(fileWrapper: wrapper)
            portable.bounds = attachment.bounds
            rendered.addAttribute(.attachment, value: portable, range: range)
        }
        let rtfd = try rendered.data(from: fullRange, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let item = NSPasteboardItem()
        item.setString(content.plainText, forType: .string)
        item.setData(try JSONEncoder().encode(content), forType: blocksType)
        item.setData(rtfd, forType: .rtfd)
        item.setString(html(content, imageData: imageData, audioData: audioData), forType: .html)
        board.clearContents()
        guard board.writeObjects([item]) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func inline(_ block: NoteBlock) -> String {
        let text = block.text as NSString
        var boundaries: Set<Int> = [0, text.length]
        for mark in block.marks { boundaries.insert(mark.location); boundaries.insert(mark.location + mark.length) }
        let sorted = boundaries.sorted()
        return zip(sorted, sorted.dropFirst()).map { start, end in
            var value = escape(text.substring(with: NSRange(location: start, length: end - start))).replacingOccurrences(of: "\n", with: "<br>")
            for mark in block.marks where mark.location <= start && mark.location + mark.length >= end {
                if mark.bold { value = "<strong>\(value)</strong>" }
                if mark.italic { value = "<em>\(value)</em>" }
                if mark.strikethrough { value = "<s>\(value)</s>" }
                if mark.code { value = "<code>\(value)</code>" }
                if let url = mark.clickableURL { value = "<a href=\"\(escape(url.absoluteString))\">\(value)</a>" }
            }
            return value
        }.joined()
    }

    private static func html(_ content: NoteContent, imageData: [UUID: Data], audioData: [UUID: Data]) -> String {
        var result = "<html><head><meta charset=\"utf-8\"></head><body>"
        var list: String?
        for block in content.blocks {
            let nextList = block.kind == .orderedList ? "ol" : block.kind == .bullet ? "ul" : nil
            if list != nextList {
                if let list { result += "</\(list)>" }
                if let nextList { result += "<\(nextList)>" }
                list = nextList
            }
            if let image = block.image, let data = imageData[image.id] {
                result += "<p><img src=\"data:image/png;base64,\(data.base64EncodedString())\" alt=\"\(escape(image.name))\" width=\"\(min(640, image.pixelWidth))\"></p>"
            } else if let audio = block.audio, let data = audioData[audio.id] {
                result += "<p>\(escape(audio.name)) · \(NoteAudio.timestamp(audio.duration))<br><audio controls src=\"data:\(audio.mimeType);base64,\(data.base64EncodedString())\">\(escape(audio.name))</audio></p>"
            } else if let table = block.table {
                result += "<table style=\"border-collapse:collapse\">"
                for (rowIndex, row) in table.rows.enumerated() {
                    result += "<tr>"
                    for (column, cell) in row.enumerated() {
                        let tag = table.isHeader(row: rowIndex, column: column) ? "th" : "td"
                        result += "<\(tag) style=\"border:1px solid #aaa;padding:6px\">\(escape(cell).replacingOccurrences(of: "\n", with: "<br>"))</\(tag)>"
                    }
                    result += "</tr>"
                }
                result += "</table>"
            } else if block.kind == .divider { result += "<hr>" }
            else if block.kind == .code {
                result += "<pre><code class=\"language-\(block.language.grammarName)\">\(escape(block.text))</code></pre>"
            } else {
                let tag = block.kind.headingLevel.map { "h\($0)" } ?? (nextList != nil ? "li" : block.kind == .quote ? "blockquote" : "p")
                result += "<\(tag)>" + (block.kind == .task ? (block.isChecked ? "☑ " : "☐ ") : "") + inline(block) + "</\(tag)>"
            }
        }
        if let list { result += "</\(list)>" }
        return result + "</body></html>"
    }
}

nonisolated private struct NoteAudioCopyError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
