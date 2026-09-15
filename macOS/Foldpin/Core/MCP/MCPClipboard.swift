import AppKit
import UniformTypeIdentifiers

/// Snapshot a single explicit paste. Never keep observing the system clipboard.
nonisolated enum MCPClipboard: Sendable {
    case content(NoteContent)
    case files([URL])
    case image(Data)

    @MainActor static func capture(_ board: NSPasteboard, allowAssets: Bool,
                                  resourceIsAllowed: (NoteBlock) -> Bool) throws -> Self {
        let change = board.changeCount
        let snapshot: Self
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            guard allowAssets else { throw MCPFailure("permission_denied") }
            guard urls.count <= 32, urls.allSatisfy(\.isFileURL) else { throw MCPFailure("limit_exceeded") }
            snapshot = .files(urls)
        } else if let data = board.data(forType: .init("dev.jasonyu.foldpin.blocks.v1")) {
            guard data.count <= 2_097_152 else { throw MCPFailure("limit_exceeded") }
            var content = try JSONDecoder().decode(NoteContent.self, from: data)
            try content.validate()
            for block in content.blocks where block.image != nil || block.audio != nil || block.video != nil || block.attachment != nil {
                guard allowAssets, resourceIsAllowed(block) else { throw MCPFailure("not_found_or_denied") }
            }
            for index in content.blocks.indices { content.blocks[index].id = UUID() }
            snapshot = .content(content)
        } else if let data = board.data(forType: .png) ?? board.data(forType: .tiff) {
            guard allowAssets else { throw MCPFailure("permission_denied") }
            guard data.count <= 40 * 1024 * 1024 else { throw MCPFailure("limit_exceeded") }
            snapshot = .image(data)
        } else if let text = board.string(forType: .string) {
            guard text.utf8.count <= 1_048_576 else { throw MCPFailure("limit_exceeded") }
            snapshot = .content(MarkdownPasteParser.parse(text, importingRemoteImages: false) ?? NoteContent(plainText: text))
        } else { throw MCPFailure("unsupported") }
        guard board.changeCount == change else { throw MCPFailure("revision_conflict") }
        return snapshot
    }

    func prepare(assets: URL) async throws -> NoteContent {
        switch self {
        case .content(let content): return content
        case .image(let data):
            return NoteContent(blocks: [NoteBlock(kind: .image, image: try NoteImageImporter.prepare(data: data, name: "Image", directory: assets).image)])
        case .files(let urls):
            if urls.count == 1, let url = urls.first {
                let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true else { throw MCPFailure("invalid_input") }
                let ext = url.pathExtension.lowercased()
                if NoteVideo.extensions.contains(ext) {
                    return NoteContent(blocks: [NoteBlock(kind: .video, video: try await NoteVideoImporter.prepare(url: url, directory: assets))])
                }
                if NoteAudio.extensions.contains(ext) {
                    return NoteContent(blocks: [NoteBlock(kind: .audio, audio: try NoteAudioImporter.prepare(url: url, directory: assets))])
                }
                if UTType(filenameExtension: ext)?.conforms(to: .image) == true, ext != "svg" {
                    return NoteContent(blocks: [NoteBlock(kind: .image, image: try NoteImageImporter.prepare(url: url, directory: assets).image)])
                }
            }
            let files = try NoteAttachmentImporter.prepare(urls: urls, directory: assets.appendingPathComponent("files"))
            return NoteContent(blocks: files.map { NoteBlock(kind: .file, attachment: $0) })
        }
    }
}
