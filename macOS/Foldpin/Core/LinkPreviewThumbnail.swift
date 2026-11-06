import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A small, self-contained JPEG travels with the card's JSON, undo and clipboard
/// snapshots. It never depends on a temporary download or a remote image URL.
nonisolated enum LinkPreviewThumbnail {
    static let maximumDownloadBytes = 4 * 1024 * 1024
    static let maximumStoredBytes = 160 * 1024

    private static func source(_ data: Data) -> CGImageSource? {
        guard data.count <= maximumDownloadBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384, width * height <= 40_000_000 else { return nil }
        return source
    }

    static func image(_ data: Data, maximumSize: Int = 640) -> CGImage? {
        guard let source = source(data) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    static func prepare(_ data: Data) -> Data? {
        for size in [640, 400, 240] {
            guard let image = image(data, maximumSize: size) else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if output.length <= maximumStoredBytes { return output as Data }
        }
        return nil
    }

    static func isValid(_ data: Data) -> Bool {
        guard data.count <= maximumStoredBytes, let source = source(data),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return width <= 640 && height <= 640
    }
}
