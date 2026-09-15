import Foundation

/// A read-only inventory, deliberately independent of LibraryDisk's reconciling
/// reader and download requests. It never interprets an unreadable file as zero.
nonisolated enum LibraryUsage {
    enum Category: String, CaseIterable, Sendable {
        case current = "Current notes and collections", history = "Revision history"
        case images = "Images", audio = "Audio", video = "Video", attachments = "Attachments"
        case recovery = "Recovery files", other = "Other library files"
    }
    struct Reference: Hashable, Sendable {
        let noteID: UUID
        let title: String
        let historical: Bool
        let deleted: Bool
    }
    struct Item: Identifiable, Sendable {
        var id: String { relativePath }
        let relativePath: String
        let bytes: Int64
        let allocatedBytes: Int64?
        let modified: Date?
        var category: Category
        var references: [Reference] = []
    }
    struct Report: Sendable {
        let root: URL
        let date: Date
        var items: [Item]
        var incomplete: Bool
        var total: Int64 { items.reduce(0) { $0 + $1.bytes } }
        var largestResources: [Item] {
            items.filter { [.images, .audio, .video, .attachments].contains($0.category) }.sorted { $0.bytes > $1.bytes }
        }
        func bytes(_ category: Category) -> Int64 { items.filter { $0.category == category }.reduce(0) { $0 + $1.bytes } }
    }
    private struct Record { let path: String; let kind: String; let revision: LibraryRevision }
    static func scan(root: URL) throws -> Report {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            .totalFileAllocatedSizeKey, .contentModificationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true else { throw LibraryStorageError.unavailable }
        var failed = false
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in failed = true; return true }) else { throw LibraryStorageError.unavailable }
        var items: [Item] = [], records: [Record] = [], legacy: [(String, NoteDocument)] = []
        var manifest: LibraryManifest?
        var paths = Set<String>()
        let managed = fm.fileExists(atPath: root.appendingPathComponent("library.json").path)
        for case let url as URL in iterator {
            try Task.checkCancellation()
            let relative = String(url.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(root.path.count + 1))
            let info: URLResourceValues
            do { info = try url.resourceValues(forKeys: keys) } catch { failed = true; iterator.skipDescendants(); continue }
            if info.isSymbolicLink == true { failed = true; iterator.skipDescendants(); continue }
            if info.isDirectory == true {
                if info.isUbiquitousItem == true && info.ubiquitousItemDownloadingStatus == .notDownloaded { failed = true; iterator.skipDescendants() }
                continue
            }
            guard info.isRegularFile == true else { failed = true; continue }
            paths.insert(relative)
            let available = !url.lastPathComponent.hasSuffix(".icloud") && (info.isUbiquitousItem != true || info.ubiquitousItemDownloadingStatus == .current || info.ubiquitousItemDownloadingStatus == .downloaded)
            if !available || info.fileSize == nil { failed = true }
            var category: Category = .other
            if relative.hasPrefix("assets/files/") { category = .attachments }
            else if relative.hasPrefix("assets/") {
                let ext = url.pathExtension.lowercased()
                if NoteAudio.extensions.contains(ext) { category = .audio }
                else if NoteVideo.extensions.contains(ext) || relative.hasSuffix(".poster.jpg") { category = .video }
                else if ["png", "original", "jpg", "jpeg"].contains(ext) { category = .images }
            } else if relative.hasPrefix("revisions/") { category = .history }
            else if relative.hasPrefix("notes/") || relative == "note.json" || relative == "collections.json" { category = managed ? .recovery : .current }
            else if relative.hasPrefix("backups/") { category = .recovery }
            items.append(Item(relativePath: relative, bytes: Int64(info.fileSize ?? 0), allocatedBytes: info.totalFileAllocatedSize.map(Int64.init), modified: info.contentModificationDate, category: category))
            guard available, url.pathExtension == "json", !relative.hasPrefix("assets/") else { continue }
            do {
                guard let size = info.fileSize, size <= 64 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                let data = try Data(contentsOf: url)
                if relative == "library.json" {
                    manifest = try JSONDecoder().decode(LibraryManifest.self, from: data); try manifest?.validate()
                } else if relative.hasPrefix("revisions/") {
                    let parts = relative.split(separator: "/")
                    let record = try JSONDecoder().decode(LibraryRevision.self, from: data)
                    guard parts.count == 4, ["notes", "collections"].contains(String(parts[1])), record.version == 1,
                          UUID(uuidString: String(parts[2])) == record.objectID, url.deletingPathExtension().lastPathComponent == record.id.uuidString,
                          !record.parents.contains(record.id), Set(record.parents).count == record.parents.count else { throw LibraryStorageError.unrecognized }
                    if let payload = record.payload { try LibraryDisk.validate(payload, kind: String(parts[1]), id: record.objectID) }
                    records.append(Record(path: relative, kind: String(parts[1]), revision: record))
                } else if relative == "notes/requires-foldpin-3.json", managed {
                    guard (try JSONSerialization.jsonObject(with: data) as? [String: Int])?["version"] == 3 else { throw LibraryStorageError.unrecognized }
                } else if relative.hasPrefix("notes/") || relative == "note.json" || relative.hasPrefix("backups/") {
                    let note = try JSONDecoder().decode(NoteDocument.self, from: data); try note.validate(); legacy.append((relative, note))
                }
            } catch { failed = true }
        }
        if managed && manifest == nil { failed = true }
        if let manifest, !Set(manifest.baseline).isSubset(of: paths) { failed = true }
        var references: [String: Set<Reference>] = [:]
        func associate(_ note: NoteDocument, historical: Bool) {
            let reference = Reference(noteID: note.id, title: String(note.content.plainText.split(whereSeparator: \.isNewline).first ?? ""), historical: historical, deleted: note.deletedAt != nil)
            for path in assetPaths(note) { references[path, default: []].insert(reference); if !paths.contains(path) { failed = true } }
        }
        let groups = Dictionary(grouping: records) { $0.kind + "/" + $0.revision.objectID.uuidString }
        var heads = Set<String>()
        for group in groups.values {
            let ids = Set(group.map { $0.revision.id }), parents = Set(group.flatMap { $0.revision.parents })
            if !parents.isSubset(of: ids) { failed = true }
            if ids.count != group.count || ids.subtracting(parents).isEmpty { failed = true }
            for record in group {
                let historical = parents.contains(record.revision.id)
                if !historical { heads.insert(record.path) }
                if record.kind == "notes", let data = record.revision.payload, let note = try? JSONDecoder().decode(NoteDocument.self, from: data) { associate(note, historical: historical) }
            }
        }
        for (_, note) in legacy { associate(note, historical: managed) }
        for i in items.indices {
            if heads.contains(items[i].relativePath) { items[i].category = .current }
            items[i].references = Array(references[items[i].relativePath] ?? []).sorted { $0.noteID.uuidString < $1.noteID.uuidString }
        }
        var observed = Set<String>()
        guard let check = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]) else { throw LibraryStorageError.changed }
        let initial = Dictionary(uniqueKeysWithValues: items.map { ($0.relativePath, $0) })
        for case let url as URL in check {
            try Task.checkCancellation()
            let value = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            if value.isSymbolicLink == true { check.skipDescendants(); continue }
            guard value.isRegularFile == true else { continue }
            let relative = String(url.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(root.path.count + 1))
            observed.insert(relative)
            guard let old = initial[relative], old.bytes == Int64(value.fileSize ?? 0), old.modified == value.contentModificationDate else { throw LibraryStorageError.changed }
        }
        guard observed == Set(initial.keys) else { throw LibraryStorageError.changed }
        return Report(root: root, date: Date(), items: items, incomplete: failed)
    }
    static func assetPaths(_ note: NoteDocument) -> Set<String> {
        var result = Set<String>()
        for block in note.content.blocks {
            if let image = block.image, !image.isRemotePlaceholder {
                result.insert("assets/\(image.id.uuidString).png"); result.insert("assets/\(image.id.uuidString).original")
            }
            if let audio = block.audio { result.insert("assets/\(audio.id.uuidString).\(audio.fileExtension)") }
            if let video = block.video { result.insert("assets/\(video.id.uuidString).\(video.fileExtension)"); result.insert("assets/\(video.id.uuidString).poster.jpg") }
            if let file = block.attachment { result.insert("assets/files/\(file.id.uuidString)/\(file.name)") }
        }
        return result
    }
}
