import Foundation

nonisolated struct NoteVideo: Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var fileExtension: String
    var duration: Double
    var pixelWidth: Double
    var pixelHeight: Double

    static let extensions: Set<String> = ["mp4", "mov", "m4v"]
    var isValid: Bool {
        Self.extensions.contains(fileExtension) && !name.isEmpty && name.count <= 1024
            && duration.isFinite && duration > 0
            && pixelWidth.isFinite && pixelHeight.isFinite
            && pixelWidth > 0 && pixelHeight > 0 && pixelWidth <= 32768 && pixelHeight <= 32768
    }
    var mimeType: String { fileExtension == "mov" ? "video/quicktime" : "video/mp4" }
}
