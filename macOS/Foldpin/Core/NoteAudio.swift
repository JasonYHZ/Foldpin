import Foundation

nonisolated struct NoteAudio: Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var fileExtension: String
    var duration: Double
    var waveform: [Float] = []
    var isDraft = false

    static let extensions: Set<String> = ["m4a", "mp3", "wav", "aif", "aiff", "caf", "aac", "flac"]
    var isValid: Bool {
        Self.extensions.contains(fileExtension) && !name.isEmpty && name.count <= 1024
            && duration.isFinite && duration >= 0 && (isDraft || duration > 0)
            && waveform.count <= 128 && waveform.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
    }
    var mimeType: String {
        switch fileExtension {
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "aif", "aiff": "audio/aiff"
        case "flac": "audio/flac"
        case "caf": "audio/x-caf"
        case "aac": "audio/aac"
        default: "audio/mp4"
        }
    }
    static func timestamp(_ seconds: Double) -> String {
        let value = Int(min(359999, max(0, seconds.isFinite ? seconds : 0)))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
    }
}
