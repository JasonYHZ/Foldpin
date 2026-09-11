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
        var videoData: [UUID: Data] = [:]
        for video in content.blocks.compactMap(\.video) where videoData[video.id] == nil {
            let url = file.videoURL(video)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 32 * 1024 * 1024 - audioBytes else {
                throw NoteAudioCopyError(message: String(localized: "For media over 32 MB, use Export instead of copying.", bundle: LanguageSettings.shared.bundle))
            }
            let data = try Data(contentsOf: url)
            audioBytes += data.count; videoData[video.id] = data
        }
        var imageData: [UUID: Data] = [:]
        for block in content.blocks {
            guard let image = block.image, !image.isRemotePlaceholder else { continue }
            let data = try Data(contentsOf: file.imageURL(image.id))
            guard NSImage(data: data) != nil else { throw NoteFileError.missingImage }
            imageData[image.id] = data
        }
        var portableContent = content
        for index in portableContent.blocks.indices {
            let block = portableContent.blocks[index]
            if block.image?.isRemotePlaceholder == true {
                portableContent.blocks[index] = NoteBlock(id: block.id, text: block.plainText)
            }
        }
        let rendered = NSMutableAttributedString(attributedString: BlockTextCodec.render(
            portableContent, color: .black, width: 640, theme: .github, cachedSyntaxOnly: true,
            image: { imageData[$0.id].flatMap(NSImage.init(data:)) }))
        let fullRange = NSRange(location: 0, length: rendered.length)
        var captions: [(Int, String)] = []
        rendered.enumerateAttribute(.attachment, in: fullRange) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            if let metadata = rendered.attribute(.blockVideo, at: range.location, effectiveRange: nil) as? Data,
               let video = try? JSONDecoder().decode(NoteVideo.self, from: metadata), let data = videoData[video.id] {
                let wrapper = FileWrapper(regularFileWithContents: data)
                wrapper.preferredFilename = "video-\(video.id).\(video.fileExtension)"
                rendered.addAttribute(.attachment, value: NSTextAttachment(fileWrapper: wrapper), range: range)
                return
            }
            if let metadata = rendered.attribute(.blockAudio, at: range.location, effectiveRange: nil) as? Data,
               let audio = try? JSONDecoder().decode(NoteAudio.self, from: metadata), let data = audioData[audio.id] {
                let wrapper = FileWrapper(regularFileWithContents: data)
                wrapper.preferredFilename = "audio-\(audio.id).\(audio.fileExtension)"
                rendered.addAttribute(.attachment, value: NSTextAttachment(fileWrapper: wrapper), range: range)
                return
            }
            if let metadata = rendered.attribute(.blockImage, at: range.location, effectiveRange: nil) as? Data,
               let asset = try? JSONDecoder().decode(NoteImage.self, from: metadata), let png = imageData[asset.id] {
                let wrapper = FileWrapper(regularFileWithContents: png)
                wrapper.preferredFilename = "image-\(asset.id).png"
                let portable = NSTextAttachment(fileWrapper: wrapper)
                portable.bounds = NSRect(origin: .zero, size: ImageBlockLayout(image: asset, availableWidth: 640).imageSize)
                rendered.addAttribute(.attachment, value: portable, range: range)
                if let link = asset.clickableLink { rendered.addAttribute(.link, value: link, range: range) }
                if let caption = asset.caption, !caption.isEmpty { captions.append((NSMaxRange(range), caption)) }
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
        for (location, caption) in captions.reversed() {
            rendered.insert(NSAttributedString(string: "\n" + caption, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.darkGray]), at: location)
        }
        let rtfd = try rendered.data(from: NSRange(location: 0, length: rendered.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let item = NSPasteboardItem()
        item.setString(content.plainText, forType: .string)
        item.setData(try JSONEncoder().encode(content), forType: blocksType)
        item.setData(rtfd, forType: .rtfd)
        item.setString(html(content, imageData: imageData, audioData: audioData, videoData: videoData), forType: .html)
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

    private static func html(_ content: NoteContent, imageData: [UUID: Data], audioData: [UUID: Data], videoData: [UUID: Data]) -> String {
        var result = "<html><head><meta charset=\"utf-8\"></head><body>"
        var list: String?
        for block in content.blocks {
            let nextList = block.kind == .orderedList ? "ol" : block.kind == .bullet ? "ul" : nil
            if list != nextList {
                if let list { result += "</\(list)>" }
                if let nextList { result += "<\(nextList)>" }
                list = nextList
            }
            if block.image?.isRemotePlaceholder == true {
                result += "<p>\(escape(block.plainText))</p>"
            } else if let image = block.image, let data = imageData[image.id] {
                let width = Int(ImageBlockLayout(image: image, availableWidth: 640).imageSize.width)
                result += "<figure>"
                if let link = image.clickableLink { result += "<a href=\"\(escape(link.absoluteString))\">" }
                result += "<img src=\"data:image/png;base64,\(data.base64EncodedString())\" alt=\"\(escape(image.name))\" width=\"\(width)\">"
                if image.clickableLink != nil { result += "</a>" }
                if let caption = image.caption, !caption.isEmpty { result += "<figcaption>\(escape(caption))</figcaption>" }
                result += "</figure>"
            } else if let video = block.video, let data = videoData[video.id] {
                result += "<p>\(escape(video.name)) · \(NoteAudio.timestamp(video.duration))<br><video controls preload=\"none\" src=\"data:\(video.mimeType);base64,\(data.base64EncodedString())\">\(escape(video.name))</video></p>"
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
