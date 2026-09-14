import Foundation
import CryptoKit

nonisolated struct LibraryPreparedLocation: Sendable {
    let root: URL
    let manifest: LibraryManifest
    let snapshot: LibrarySnapshot
    let desktops: [NoteDocument]
}
nonisolated struct LibraryMoveJournal: Codable, Sendable {
    let id: UUID
    let source: URL
    let destination: URL
    let staging: URL
    var stage: String
    var sourceDigest: Data?
    var destinationDigest: Data?
}

nonisolated enum LibraryRelocation {
    struct FileItem: Equatable, Codable { let name: String; let size: Int; let digest: Data }
    static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let a = child.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let b = parent.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return a.count >= b.count && Array(a.prefix(b.count)) == b
    }
    static func digest(_ url: URL, copyingTo destination: URL? = nil) throws -> (Int, Data) {
        try LibraryDisk.ready(url)
        return try LibraryDisk.coordinated(url) { source in
            let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
            var output: FileHandle?
            if let destination {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw LibraryStorageError.unavailable }
                output = try FileHandle(forWritingTo: destination)
            }
            defer { try? output?.close() }
            var hash = SHA256(); var count = 0
            while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
                try Task.checkCancellation()
                count += bytes.count; hash.update(data: bytes); try output?.write(contentsOf: bytes)
            }
            try output?.synchronize()
            return (count, Data(hash.finalize()))
        }
    }
    static func inventory(_ root: URL, copyingTo target: URL? = nil, progress: @Sendable (Double) -> Void = { _ in }) throws -> [FileItem] {
        try LibraryDisk.ready(root)
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        var traversalError: Error?
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], errorHandler: { _, error in traversalError = error; return false }) else { throw LibraryStorageError.unavailable }
        var files: [URL] = []
        for case let url as URL in walker {
            try Task.checkCancellation(); try LibraryDisk.ready(url)
            let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard info.isSymbolicLink != true else { throw LibraryStorageError.unsafePath }
            guard info.isDirectory == true || info.isRegularFile == true else { throw LibraryStorageError.unsafePath }
            if info.isRegularFile == true { files.append(url) }
            else if let target {
                let name = String(url.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(root.path.count + 1))
                try FileManager.default.createDirectory(at: target.appendingPathComponent(name), withIntermediateDirectories: true)
            }
        }
        if let traversalError { throw traversalError }
        var result: [FileItem] = []
        for (index, url) in files.sorted(by: { $0.path < $1.path }).enumerated() {
            let name = String(url.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(root.path.count + 1))
            let (size, hash) = try digest(url, copyingTo: target?.appendingPathComponent(name))
            result.append(FileItem(name: name, size: size, digest: hash)); progress(Double(index + 1) / Double(max(1, files.count)))
        }
        return result
    }
    /// Read-only validation. Never invoke NoteLibrary's legacy auto-create path
    /// on a folder selected by the user.
    static func probe(_ root: URL) throws -> (LibraryManifest?, [NoteDocument]) {
        try LibraryDisk.ready(root)
        let info = try root.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey, .volumeIsReadOnlyKey])
        guard info.isDirectory == true, info.volumeIsLocal == true, info.volumeIsReadOnly != true else { throw LibraryStorageError.unsafePath }
        let manifestURL = root.appendingPathComponent(LibraryDisk.manifestName)
        let placeholder = root.appendingPathComponent("." + LibraryDisk.manifestName + ".icloud")
        if FileManager.default.fileExists(atPath: placeholder.path) { try LibraryDisk.ready(placeholder) }
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let manifest = try LibraryDisk.manifest(at: root)
            return (manifest, [])
        }
        let notes = root.appendingPathComponent("notes")
        guard FileManager.default.fileExists(atPath: notes.path) else { throw LibraryStorageError.unrecognized }
        var documents: [NoteDocument] = []
        for url in try FileManager.default.contentsOfDirectory(at: notes, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { throw LibraryStorageError.unrecognized }
            let note = try JSONDecoder().decode(NoteDocument.self, from: LibraryDisk.read(url))
            try note.validate(); guard note.id == id else { throw LibraryStorageError.unrecognized }
            documents.append(note)
        }
        guard !documents.isEmpty || FileManager.default.fileExists(atPath: root.appendingPathComponent("library-kept-empty").path) else { throw LibraryStorageError.unrecognized }
        return (nil, documents)
    }
    static func validateAssets(_ notes: [NoteDocument], root: URL) throws {
        let assets = root.appendingPathComponent("assets")
        for note in notes {
            for block in note.content.blocks {
                var urls: [URL] = []
                if let image = block.image, !image.isRemotePlaceholder {
                    urls += [assets.appendingPathComponent(image.id.uuidString + ".png"), assets.appendingPathComponent(image.id.uuidString + ".original")]
                }
                if let audio = block.audio { urls.append(assets.appendingPathComponent(audio.id.uuidString + "." + audio.fileExtension)) }
                if let video = block.video { urls.append(assets.appendingPathComponent(video.id.uuidString + "." + video.fileExtension)) }
                if let attachment = block.attachment { urls.append(attachment.url(in: assets.appendingPathComponent("files"))) }
                for url in urls {
                    try LibraryDisk.ready(url)
                    guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw LibraryStorageError.unrecognized }
                }
            }
        }
    }
    static func initialize(_ root: URL, manifest: LibraryManifest, notes: [NoteDocument]) throws {
        try validateAssets(notes, root: root)
        var manifest = manifest
        for note in notes {
            _ = try LibraryDisk.save(LibraryDisk.encode(LibraryDisk.shared(note)), id: note.id, parent: nil, root: root, kind: "notes")
        }
        let collections = root.appendingPathComponent("collections.json")
        if FileManager.default.fileExists(atPath: collections.path) {
            struct LegacyCollections: Decodable { let version: Int; let collections: [LibraryCollection] }
            let legacy = try JSONDecoder().decode(LegacyCollections.self, from: LibraryDisk.read(collections))
            guard legacy.version == 1, Set(legacy.collections.map(\.id)).count == legacy.collections.count else { throw LibraryStorageError.unrecognized }
            for value in legacy.collections { _ = try LibraryDisk.save(LibraryDisk.encode(value), id: value.id, parent: nil, root: root, kind: "collections") }
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        // Old releases reject a non-UUID .json in notes before they permit any
        // new writes. Keep original legacy files intact for recovery.
        try Data("{\"version\":3}".utf8).write(to: root.appendingPathComponent("notes/requires-foldpin-3.json"), options: .atomic)
        let revisionRoot = root.appendingPathComponent("revisions")
        if FileManager.default.fileExists(atPath: revisionRoot.path) {
            manifest.baseline = try inventory(revisionRoot).map { "revisions/" + $0.name }
        }
        try LibraryDisk.encode(manifest).write(to: root.appendingPathComponent(LibraryDisk.manifestName), options: .atomic)
    }
    static func copy(source: URL, destination: URL, journalURL: URL, progress: @Sendable (Double) -> Void = { _ in }) throws -> LibraryPreparedLocation {
        guard !isInside(destination, source), !isInside(source, destination) else { throw LibraryStorageError.unsafePath }
        let (existing, notes) = try probe(source)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard let data = try? Data(contentsOf: journalURL),
                  let journal = try? JSONDecoder().decode(LibraryMoveJournal.self, from: data),
                  journal.stage == "ready",
                  journal.source.resolvingSymlinksInPath().path == source.resolvingSymlinksInPath().path,
                  journal.destination.resolvingSymlinksInPath().path == destination.resolvingSymlinksInPath().path,
                  journal.sourceDigest == Data(SHA256.hash(data: try LibraryDisk.encode(inventory(source)))),
                  journal.destinationDigest == Data(SHA256.hash(data: try LibraryDisk.encode(inventory(destination))))
            else { throw LibraryStorageError.occupied }
            let manifest = try LibraryDisk.manifest(at: destination)
            return try LibraryPreparedLocation(root: destination, manifest: manifest, snapshot: LibraryDisk.snapshot(destination), desktops: notes)
        }
        let id = UUID()
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".foldpin-move-" + id.uuidString)
        var journal = LibraryMoveJournal(id: id, source: source, destination: destination, staging: staging, stage: "copying")
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LibraryDisk.encode(journal).write(to: journalURL, options: .atomic)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        var promoted = false
        defer { if !promoted { try? FileManager.default.removeItem(at: staging) } }
        let before = try inventory(source, copyingTo: staging, progress: progress)
        guard try inventory(staging) == before, try inventory(source) == before else { throw LibraryStorageError.changed }
        var manifest = existing ?? LibraryManifest()
        let desktops = existing == nil ? try probe(staging).1 : []
        if existing == nil { try initialize(staging, manifest: manifest, notes: desktops); manifest = try LibraryDisk.manifest(at: staging) }
        let snapshot = try LibraryDisk.snapshot(staging)
        let allNotes = try snapshot.notes.values.compactMap { object -> NoteDocument? in
            guard let payload = object.payload else { return nil }
            return try JSONDecoder().decode(NoteDocument.self, from: payload)
        }
        try validateAssets(allNotes, root: staging)
        try Task.checkCancellation()
        try LibraryDisk.coordinated(destination, writing: true) { try FileManager.default.moveItem(at: staging, to: $0) }
        promoted = true
        journal.stage = "ready"
        journal.sourceDigest = Data(SHA256.hash(data: try LibraryDisk.encode(before)))
        journal.destinationDigest = Data(SHA256.hash(data: try LibraryDisk.encode(inventory(destination))))
        try LibraryDisk.encode(journal).write(to: journalURL, options: .atomic)
        return LibraryPreparedLocation(root: destination, manifest: manifest, snapshot: snapshot, desktops: desktops)
    }
}
