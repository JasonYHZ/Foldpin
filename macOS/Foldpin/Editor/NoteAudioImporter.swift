import AVFoundation
import Foundation

nonisolated enum NoteAudioImporter {
    static func inspect(url: URL, name: String, id: UUID = UUID()) throws -> NoteAudio {
        let ext = url.pathExtension.lowercased()
        guard NoteAudio.extensions.contains(ext) else { throw CocoaError(.fileReadCorruptFile) }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let duration = Double(file.length) / format.sampleRate
        guard duration.isFinite, duration > 0, format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw CocoaError(.fileReadCorruptFile) }
        var peaks = [Float](repeating: 0, count: 128)
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let start = file.framePosition
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData else { break }
            for offset in stride(from: 0, to: Int(buffer.frameLength), by: 16) {
                let bin = min(127, Int(Double(start + Int64(offset)) / Double(file.length) * 128))
                var peak: Float = 0
                for channel in 0..<Int(format.channelCount) { peak = max(peak, abs(samples[channel][offset])) }
                peaks[bin] = max(peaks[bin], min(1, peak.isFinite ? peak : 0))
            }
        }
        return NoteAudio(id: id, name: name, fileExtension: ext, duration: duration, waveform: peaks)
    }

    static func prepare(url: URL, directory: URL) throws -> NoteAudio {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, (info.fileSize ?? Int.max) <= 500 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let id = UUID()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(id.uuidString + "." + url.pathExtension.lowercased())
        let staging = directory.appendingPathComponent(id.uuidString + ".importing")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: url, to: staging)
        try FileManager.default.moveItem(at: staging, to: target)
        do { return try inspect(url: target, name: String(url.deletingPathExtension().lastPathComponent.prefix(1024)), id: id) }
        catch { try? FileManager.default.removeItem(at: target); throw error }
    }
}
