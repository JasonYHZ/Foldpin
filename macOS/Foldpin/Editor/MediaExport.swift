import AppKit
import ImageIO
import UniformTypeIdentifiers

/// An immutable source selected by block UUID before presenting the save panel.
/// Export copies the asset bytes, never the editor's rendered attachment.
nonisolated struct MediaExport: Sendable {
    let sourceURL: URL
    let filename: String
    let contentType: UTType

    static func image(at url: URL, name: String, fallback: String) throws -> Self {
        try requireFile(url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String), let ext = type.preferredFilenameExtension else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return Self(sourceURL: url, filename: filename(name, extension: ext, fallback: fallback), contentType: type)
    }

    static func video(at url: URL, video: NoteVideo, fallback: String) throws -> Self {
        guard video.isValid else { throw CocoaError(.fileReadCorruptFile) }
        try requireFile(url)
        let type: UTType = video.fileExtension == "mov" ? .quickTimeMovie : .mpeg4Movie
        return Self(sourceURL: url, filename: filename(video.name, extension: video.fileExtension, fallback: fallback), contentType: UTType(filenameExtension: video.fileExtension) ?? type)
    }

    static func audio(at url: URL, audio: NoteAudio, fallback: String) throws -> Self {
        guard audio.isValid, !audio.isDraft else { throw CocoaError(.fileReadCorruptFile) }
        try requireFile(url)
        return Self(sourceURL: url, filename: filename(audio.name, extension: audio.fileExtension, fallback: fallback),
                    contentType: UTType(filenameExtension: audio.fileExtension) ?? .audio)
    }

    private static func filename(_ name: String, extension ext: String, fallback: String) -> String {
        var base = name.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
            .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = (base as NSString).pathExtension
        // Common extensions must not depend on Launch Services being available.
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "avif", "jp2", "ico", "icns"]
        if previous.lowercased() == ext.lowercased()
            || imageExtensions.contains(previous.lowercased())
            || UTType(filenameExtension: previous)?.conforms(to: .image) == true
            || NoteAudio.extensions.contains(previous.lowercased())
            || NoteVideo.extensions.contains(previous.lowercased()) {
            base = (base as NSString).deletingPathExtension
        }
        base = String(base.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).prefix(100))
        return (base.isEmpty ? fallback : base) + "." + ext
    }

    private static func requireFile(_ url: URL) throws {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
    }

    func write(to destination: URL) throws {
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        try Self.requireFile(sourceURL)
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        try data.write(to: destination, options: .atomic)
    }

    @MainActor func present(in window: NSWindow) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                do { try await Task.detached(priority: .userInitiated) { try self.write(to: destination) }.value }
                catch { Self.showError(error, in: window) }
            }
        }
    }

    @MainActor static func showError(_ error: Error, in window: NSWindow) {
        let bundle = LanguageSettings.shared.bundle
        let alert = NSAlert()
        alert.messageText = String(localized: "Could not export media", bundle: bundle)
        alert.informativeText = String(localized: "Check that the original file is available and choose a writable location.", bundle: bundle)
            + "\n" + error.localizedDescription
        alert.beginSheetModal(for: window)
    }
}
