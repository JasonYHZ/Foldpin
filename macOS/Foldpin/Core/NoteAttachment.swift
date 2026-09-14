import Foundation

nonisolated struct NoteAttachment: Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var byteCount: Int64
    var isValid: Bool {
        !name.isEmpty && name.utf8.count <= 1024 && name != "." && name != ".."
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:\\")).contains($0) }
            && byteCount >= 0 && byteCount <= 512 * 1024 * 1024
    }
    func url(in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent(name)
    }
}

nonisolated enum NoteAttachmentImporter {
    static let byteLimit: Int64 = 512 * 1024 * 1024
    static func prepare(urls: [URL], directory: URL) throws -> [NoteAttachment] {
        guard !urls.isEmpty, urls.count <= 32 else { throw CocoaError(.fileReadTooLarge) }
        var prepared: [NoteAttachment] = []
        var created: [URL] = []
        var succeeded = false
        defer { if !succeeded { for folder in created { try? FileManager.default.removeItem(at: folder) } } }
        var total: Int64 = 0
        for url in urls {
            try Task.checkCancellation()
            guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, info.isPackage != true,
                  let bytes = info.fileSize, Int64(bytes) <= byteLimit - total else { throw CocoaError(.fileReadTooLarge) }
            var attachment = NoteAttachment(name: url.lastPathComponent, byteCount: Int64(bytes))
            guard attachment.isValid else { throw CocoaError(.fileReadInvalidFileName) }
            let target = attachment.url(in: directory)
            let folder = target.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            created.append(folder)
            let staging = folder.appendingPathComponent(".importing-" + UUID().uuidString)
            // Preserve source bytes, quarantine and other file attributes. Never
            // execute, unpack or rewrite imported documents.
            try FileManager.default.copyItem(at: url, to: staging)
            let actual = try staging.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard actual.isRegularFile == true, actual.isSymbolicLink != true,
                  let size = actual.fileSize, Int64(size) <= byteLimit - total else { throw CocoaError(.fileReadTooLarge) }
            attachment.byteCount = Int64(size)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: staging, to: target)
            total += attachment.byteCount
            prepared.append(attachment)
        }
        succeeded = true
        return prepared
    }
    static func removeUninserted(_ values: [NoteAttachment], directory: URL) {
        for value in values { try? FileManager.default.removeItem(at: value.url(in: directory).deletingLastPathComponent()) }
    }
}
