import Foundation

nonisolated enum MarkdownFileImport {
    static let fileLimit = 5 * 1024 * 1024
    static let batchLimit = 25 * 1024 * 1024
    static let resourceLimit = 512 * 1024 * 1024
    struct Prepared: Sendable {
        let content: NoteContent
        let warnings: [String]
        let resourceBytes: Int
    }
    static func decode(_ data: Data) throws -> String {
        guard data.count <= fileLimit else { throw CocoaError(.fileReadTooLarge) }
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let text = String(data: data.dropFirst(3), encoding: .utf8) { return text }
        if data.starts(with: [0xFF, 0xFE]), let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) { return text }
        if data.starts(with: [0xFE, 0xFF]), let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) { return text }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return text
    }
    /// Only local regular files below the user-authorized resource directory.
    /// Reject every symlink component, including links which currently point inside.
    static func localResource(_ reference: String, source: URL, authorizedRoot: URL) throws -> URL {
        guard let link = URL(string: reference), link.scheme == nil || link.isFileURL,
              link.query == nil, link.fragment == nil else { throw CocoaError(.fileReadUnsupportedScheme) }
        let root = authorizedRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = link.isFileURL ? link : URL(fileURLWithPath: link.path, relativeTo: source.deletingLastPathComponent())
        let target = candidate.standardizedFileURL
        guard target.path.hasPrefix(root.path + "/"), !link.path.components(separatedBy: "/").contains("..") else { throw LibraryStorageError.unsafePath }
        var current = root
        for part in target.path.dropFirst(root.path.count + 1).split(separator: "/") {
            current.appendPathComponent(String(part))
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw LibraryStorageError.unsafePath }
        }
        let info = try target.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard info.isRegularFile == true, info.isPackage != true else { throw LibraryStorageError.unsafePath }
        if info.isUbiquitousItem == true && info.ubiquitousItemDownloadingStatus == .notDownloaded { throw LibraryStorageError.downloading }
        return target
    }
    static func prepare(source: String, sourceURL: URL, authorizedRoot: URL?, staging: URL,
                        remainingBytes: Int = resourceLimit) throws -> Prepared {
        var blocks: [NoteBlock] = [], pending: [String] = [], warnings = Set<String>(), bytes = 0
        var fence: Character?, fenceLength = 0
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        func flush() {
            guard !pending.isEmpty else { return }
            let text = pending.joined(separator: "\n")
            blocks += (MarkdownPasteParser.parse(text, importingRemoteImages: false) ?? NoteContent(plainText: text)).blocks
            pending.removeAll()
        }
        let standalone = try NSRegularExpression(pattern: #"^(!?)\[([^\]]*)\]\((?:<([^>]+)>|([^\s\)]+))\)$"#)
        var index = 0
        // Preserve front matter literally; its separators must not become UI dividers.
        if lines.first == "---", let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) {
            blocks.append(NoteBlock(text: lines[0...end].joined(separator: "\n")))
            warnings.insert("Some Markdown was kept as source text."); index = end + 1
        }
        while index < lines.count {
            try Task.checkCancellation()
            let raw = lines[index], line = raw.trimmingCharacters(in: .whitespaces)
            index += 1
            if let first = line.first, first == "`" || first == "~" {
                let count = line.prefix(while: { $0 == first }).count
                if count >= 3 {
                    if fence == nil { fence = first; fenceLength = count }
                    else if fence == first && count >= fenceLength && line.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                    pending.append(raw); continue
                }
            }
            guard fence == nil else { pending.append(raw); continue }
            if let match = standalone.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                func capture(_ i: Int) -> String { Range(match.range(at: i), in: line).map { String(line[$0]) } ?? "" }
                let reference = capture(3).isEmpty ? capture(4) : capture(3)
                let image = capture(1) == "!"
                let remote = URL(string: reference)?.scheme.map { !["file"].contains($0.lowercased()) } ?? false
                if remote {
                    // A remote image remains literal, never a pending download block.
                    if image {
                        warnings.insert("Remote images were kept as links; nothing was downloaded.")
                        flush(); blocks.append(NoteBlock(text: raw))
                    } else { pending.append(raw) }
                    continue
                }
                guard let authorizedRoot else {
                    warnings.insert("Local resource links were kept as text."); flush(); blocks.append(NoteBlock(text: raw)); continue
                }
                do {
                    let url = try localResource(reference, source: sourceURL, authorizedRoot: authorizedRoot)
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                    guard size <= remainingBytes - bytes else { throw CocoaError(.fileReadTooLarge) }
                    flush()
                    if image {
                        var value = try NoteImageImporter.prepare(url: url, directory: staging).image
                        value.caption = capture(2)
                        blocks.append(NoteBlock(kind: .image, image: value))
                    } else {
                        let values = try NoteAttachmentImporter.prepare(urls: [url], directory: staging.appendingPathComponent("files"))
                        blocks += values.map { NoteBlock(kind: .file, attachment: $0) }
                    }
                    bytes += size
                } catch is CancellationError { throw CancellationError() }
                catch {
                    warnings.insert("Some local resources could not be copied. Their original links were kept.")
                    flush()
                    blocks.append(NoteBlock(text: raw))
                }
            } else {
                if line.contains("![") || line.contains("](") || line.contains("]:") || line.contains("[[") || line.contains("<") || raw.hasPrefix("    ") {
                    warnings.insert("Some Markdown was kept as source text.")
                }
                pending.append(raw)
            }
        }
        flush()
        if blocks.isEmpty { blocks = [NoteBlock()] }
        let content = NoteContent(blocks: blocks)
        try content.validate()
        return Prepared(content: content, warnings: warnings.sorted(), resourceBytes: bytes)
    }
}
