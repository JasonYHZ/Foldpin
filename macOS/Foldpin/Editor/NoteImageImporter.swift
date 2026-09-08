import Foundation
import ImageIO
import UniformTypeIdentifiers

enum NoteImageImportError: Error {
    case tooLarge, invalidImage
}

struct PreparedNoteImage: Sendable {
    let image: NoteImage
}

enum NoteImageImporter {
    nonisolated static func prepare(data: Data, name: String, directory: URL) throws -> PreparedNoteImage {
        guard data.count <= 40 * 1_024 * 1_024 else { throw NoteImageImportError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, Double(w) * Double(h) <= 80_000_000 else { throw NoteImageImportError.invalidImage }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: 1400,
                                      kCGImageSourceShouldCacheImmediately: true]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw NoteImageImportError.invalidImage
        }
        let id = UUID()
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
            throw NoteImageImportError.invalidImage
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { throw NoteImageImportError.invalidImage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Both files must exist before a block can reference them. Orphans are
        // retained for now so undo/redo and backups never lose their attachments.
        try data.write(to: directory.appendingPathComponent(id.uuidString + ".original"), options: .atomic)
        try (bytes as Data).write(to: directory.appendingPathComponent(id.uuidString + ".png"), options: .atomic)
        return PreparedNoteImage(image: NoteImage(id: id, name: name,
                                                 pixelWidth: thumbnail.width, pixelHeight: thumbnail.height))
    }

    nonisolated static func prepare(url: URL, directory: URL) throws -> PreparedNoteImage {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 40 * 1_024 * 1_024 else {
            throw NoteImageImportError.tooLarge
        }
        return try prepare(data: Data(contentsOf: url), name: url.lastPathComponent, directory: directory)
    }
}
