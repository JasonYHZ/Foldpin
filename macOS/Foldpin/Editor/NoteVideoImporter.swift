import AVFoundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum NoteVideoImporter {
    static func asset(at url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
    }

    static func prepare(url: URL, directory: URL) async throws -> NoteVideo {
        guard url.isFileURL, NoteVideo.extensions.contains(url.pathExtension.lowercased()) else { throw CocoaError(.fileReadCorruptFile) }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, let size = info.fileSize, size > 0, size <= 1024 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let id = UUID(), ext = url.pathExtension.lowercased()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(id.uuidString + "." + ext)
        let poster = directory.appendingPathComponent(id.uuidString + ".poster.jpg")
        let staging = directory.appendingPathComponent(id.uuidString + ".importing")
        defer { try? FileManager.default.removeItem(at: staging) }
        try Task.checkCancellation()
        try FileManager.default.copyItem(at: url, to: staging)
        try FileManager.default.moveItem(at: staging, to: target)
        do {
            let asset = asset(at: target)
            guard try await asset.load(.isPlayable),
                  let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
            let duration = try await asset.load(.duration).seconds
            let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            let video = NoteVideo(id: id, name: String(url.deletingPathExtension().lastPathComponent.prefix(1024)),
                                  fileExtension: ext, duration: duration, pixelWidth: abs(rect.width), pixelHeight: abs(rect.height))
            guard video.isValid else { throw CocoaError(.fileReadCorruptFile) }
            // Decode one frame to reject unsupported codecs before inserting a block.
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 960, height: 960)
            let frame = try await generator.image(at: .zero).image
            if let output = CGImageDestinationCreateWithURL(poster as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(output, frame, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                if !CGImageDestinationFinalize(output) { try? FileManager.default.removeItem(at: poster) }
            }
            try Task.checkCancellation()
            return video
        } catch {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.removeItem(at: poster)
            throw error
        }
    }
}
