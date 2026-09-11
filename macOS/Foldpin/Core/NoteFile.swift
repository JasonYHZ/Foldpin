import Foundation

enum NoteFileError: LocalizedError {
    case unsupportedVersion
    case invalidLayout
    case invalidContent
    case missingImage
    case missingAudio
    case missingVideo

    var errorDescription: String? {
        description(bundle: .main)
    }

    func description(bundle: Bundle) -> String {
        switch self {
        case .unsupportedVersion: String(localized: "This note requires a newer version of Foldpin.", bundle: bundle)
        case .invalidLayout: String(localized: "The note has invalid position data. The original file is unchanged.", bundle: bundle)
        case .invalidContent: String(localized: "The note contains invalid blocks. The original file is unchanged.", bundle: bundle)
        case .missingVideo: String(localized: "A video file is missing. The existing note has not been overwritten.", bundle: bundle)
        case .missingAudio: String(localized: "An audio file is missing. The existing note has not been overwritten.", bundle: bundle)
        case .missingImage: String(localized: "An image file is missing. The existing note has not been overwritten.", bundle: bundle)
        }
    }
}

struct NoteFile {
    let url: URL
    var assetDirectory: URL? = nil
    var expectedID: UUID? = nil

    var assetsURL: URL { assetDirectory ?? url.deletingLastPathComponent().appendingPathComponent("assets", isDirectory: true) }
    var backupsURL: URL { url.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true) }

    func imageURL(_ id: UUID, original: Bool = false) -> URL {
        assetsURL.appendingPathComponent(id.uuidString + (original ? ".original" : ".png"))
    }

    func videoURL(_ video: NoteVideo) -> URL { assetsURL.appendingPathComponent(video.id.uuidString + "." + video.fileExtension) }
    func videoPosterURL(_ video: NoteVideo) -> URL { assetsURL.appendingPathComponent(video.id.uuidString + ".poster.jpg") }

    func audioURL(_ audio: NoteAudio) -> URL { assetsURL.appendingPathComponent(audio.id.uuidString + "." + audio.fileExtension) }

    func load() throws -> NoteDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            if expectedID != nil { throw CocoaError(.fileReadNoSuchFile) }
            return NoteDocument()
        }
        let document = try JSONDecoder().decode(NoteDocument.self, from: Data(contentsOf: url))
        try document.validate()
        if let expectedID, document.id != expectedID { throw NoteFileError.invalidContent }
        return document
    }

    func save(_ document: NoteDocument) throws {
        try document.validate()
        if let expectedID, document.id != expectedID { throw NoteFileError.invalidContent }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        // Validate the exact bytes before replacing the previous file.
        try JSONDecoder().decode(NoteDocument.self, from: data).validate()
        for block in document.content.blocks {
            if let video = block.video, !FileManager.default.fileExists(atPath: videoURL(video).path) { throw NoteFileError.missingVideo }
            if let audio = block.audio, !FileManager.default.fileExists(atPath: audioURL(audio).path) { throw NoteFileError.missingAudio }
        }
        for block in document.content.blocks where block.image != nil && block.image?.isRemotePlaceholder != true {
            let id = block.image!.id
            guard FileManager.default.fileExists(atPath: imageURL(id).path),
                  FileManager.default.fileExists(atPath: imageURL(id, original: true).path) else {
                throw NoteFileError.missingImage
            }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let original = try Data(contentsOf: url)
            let header = try JSONSerialization.jsonObject(with: original) as? [String: Any]
            if header?["version"] as? Int == 1 {
                // Back up the original bytes before the first v2 save. A failure
                // here must stop migration; never overwrite an earlier backup.
                try FileManager.default.createDirectory(at: backupsURL, withIntermediateDirectories: true)
                let backup = backupsURL.appendingPathComponent("note-v1-\(UUID().uuidString).json")
                try original.write(to: backup, options: .withoutOverwriting)
            }
        }
        // Atomic replacement leaves the previous file intact if writing the new file fails.
        try data.write(to: url, options: .atomic)
    }
}
