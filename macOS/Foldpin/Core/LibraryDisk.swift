import Foundation
import CryptoKit
import Darwin

nonisolated enum LibraryStorageError: LocalizedError {
    case unavailable, unrecognized, newerVersion, unsafePath, occupied, downloading, changed, busy, locked
    var errorDescription: String? { description(bundle: .main) }
    func description(bundle: Bundle) -> String { bundle.localizedString(forKey: message, value: message, table: nil) }
    private var message: String {
        switch self {
        case .unavailable: "The library is unavailable. Reauthorize its folder or try again."
        case .unrecognized: "This folder is not a readable Foldpin library. Existing files are unchanged."
        case .newerVersion: "This library requires a newer version of Foldpin."
        case .unsafePath: "Choose a separate local or iCloud Drive folder without symbolic links."
        case .occupied: "The destination already exists. Open that library or choose another location."
        case .downloading: "Library files are downloading from iCloud Drive. Try again when they are available."
        case .changed: "The library changed during this operation. Existing files are preserved; try again."
        case .busy: "Finish recording, importing, or exporting before changing libraries."
        case .locked: "This library is already open in another Foldpin process on this Mac."
        }
    }
}

nonisolated struct LibraryManifest: Codable, Equatable, Sendable {
    var version = 1
    var minimumReader = 3
    var id = UUID()
    var createdAt = Date()
    var baseline: [String] = []
    func validate() throws {
        guard version == 1, minimumReader <= 3 else { throw LibraryStorageError.newerVersion }
        for path in baseline {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 4, parts[0] == "revisions", ["notes", "collections"].contains(String(parts[1])),
                  UUID(uuidString: String(parts[2])) != nil, parts[3].hasSuffix(".json"),
                  UUID(uuidString: String(parts[3].dropLast(5))) != nil else { throw LibraryStorageError.unrecognized }
        }
    }
}

/// A file path shared by stores, retained media models, and clipboard/undo
/// closures. Relocation changes this reference only after all file work stops.
nonisolated final class LibraryPath: @unchecked Sendable {
    private let lock = NSLock()
    private var directory: URL
    private var format: LibraryManifest?
    private var enabled = true
    private var serial: UInt64 = 0
    private var cached = LibrarySnapshot(notes: [:], collections: [:])
    let localDirectory: URL
    init(_ directory: URL, manifest: LibraryManifest? = nil, localDirectory: URL) {
        self.directory = directory; self.format = manifest; self.localDirectory = localDirectory
    }
    var writeSerial: UInt64 { lock.withLock { serial } }
    var snapshot: LibrarySnapshot { lock.withLock { cached } }
    func install(_ snapshot: LibrarySnapshot) { lock.withLock { cached = snapshot } }
    func record(_ object: LibraryObject, kind: String) {
        lock.withLock {
            serial &+= 1
            var notes = cached.notes, collections = cached.collections
            if kind == "notes" { notes[object.id] = object } else { collections[object.id] = object }
            cached = LibrarySnapshot(notes: notes, collections: collections)
        }
    }
    var root: URL { lock.withLock { directory } }
    var manifest: LibraryManifest? { lock.withLock { format } }
    var writable: Bool { lock.withLock { enabled } }
    func setWritable(_ value: Bool) { lock.withLock { enabled = value } }
    func relocate(to url: URL, manifest: LibraryManifest) { lock.withLock { directory = url; format = manifest } }
    var desktopDirectory: URL { localDirectory.appendingPathComponent(manifest?.id.uuidString ?? "legacy").appendingPathComponent("desktop") }
}

nonisolated struct LibraryDesktopState: Codable, Equatable, Sendable {
    var frame: NoteFrame?
    var isPinned: Bool
    var isCollapsed: Bool
    var isShelved: Bool
    init(_ note: NoteDocument) { frame = note.frame; isPinned = note.isPinned; isCollapsed = note.isCollapsed; isShelved = note.isShelved }
    func apply(to note: inout NoteDocument) { note.frame = frame; note.isPinned = isPinned; note.isCollapsed = isCollapsed; note.isShelved = isShelved }
}

/// Each successful write gets its own file. iCloud transports these immutable
/// revisions; two offline writers never need to replace the same shared file.
nonisolated struct LibraryRevision: Codable, Equatable, Sendable {
    var version = 1
    let id: UUID
    let objectID: UUID
    let parents: [UUID]
    let payload: Data? // nil is a permanent deletion, retained for offline peers.
    let date: Date
}
nonisolated struct LibraryObject: Sendable {
    let id: UUID
    let revision: UUID
    let payload: Data?
}
nonisolated struct LibrarySnapshot: Sendable {
    let notes: [UUID: LibraryObject]
    let collections: [UUID: LibraryObject]
}

nonisolated enum LibraryDisk {
    static let manifestName = "library.json"
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func coordinated<T>(_ url: URL, writing: Bool = false, _ body: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator()
        var error: NSError?
        var result: Result<T, Error>?
        if writing { coordinator.coordinate(writingItemAt: url, options: [], error: &error) { url in result = Result { try body(url) } } }
        else { coordinator.coordinate(readingItemAt: url, options: [], error: &error) { url in result = Result { try body(url) } } }
        if let error { throw error }
        guard let result else { throw LibraryStorageError.unavailable }
        return try result.get()
    }
    static func ready(_ url: URL) throws {
        if url.lastPathComponent.hasPrefix("."), url.pathExtension == "icloud" {
            let name = String(url.deletingPathExtension().lastPathComponent.dropFirst())
            try? FileManager.default.startDownloadingUbiquitousItem(at: url.deletingLastPathComponent().appendingPathComponent(name))
            throw LibraryStorageError.downloading
        }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values.isSymbolicLink != true else { throw LibraryStorageError.unsafePath }
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus == .notDownloaded {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw LibraryStorageError.downloading
        }
    }
    static func read(_ url: URL) throws -> Data {
        try ready(url)
        return try coordinated(url) { try Data(contentsOf: $0) }
    }
    static func manifest(at root: URL) throws -> LibraryManifest {
        let manifest = try JSONDecoder().decode(LibraryManifest.self, from: read(root.appendingPathComponent(manifestName)))
        try manifest.validate(); return manifest
    }
    static func validateIdentity(_ path: LibraryPath) throws {
        guard try manifest(at: path.root).id == path.manifest?.id else { throw LibraryStorageError.changed }
    }
    static func shared(_ note: NoteDocument) -> NoteDocument {
        var result = note
        result.frame = nil; result.isPinned = false; result.isCollapsed = false; result.isShelved = true
        return result
    }
    static func recordDirectory(_ root: URL, kind: String, id: UUID) -> URL {
        root.appendingPathComponent("revisions").appendingPathComponent(kind).appendingPathComponent(id.uuidString)
    }
    static func write(_ revision: LibraryRevision, root: URL, kind: String) throws {
        let directory = recordDirectory(root, kind: kind, id: revision.objectID)
        for ancestor in [root, root.appendingPathComponent("revisions"), root.appendingPathComponent("revisions").appendingPathComponent(kind), directory] {
            if FileManager.default.fileExists(atPath: ancestor.path) { try ready(ancestor) }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(revision.id.uuidString + ".json")
        let data = try encode(revision)
        try coordinated(url, writing: true) { target in
            if FileManager.default.fileExists(atPath: target.path) {
                guard try Data(contentsOf: target) == data else { throw LibraryStorageError.changed }
            } else { try data.write(to: target, options: .atomic) }
        }
    }
    static func save(_ payload: Data?, id: UUID, parent: UUID?, root: URL, kind: String) throws -> UUID {
        let revision = LibraryRevision(id: UUID(), objectID: id, parents: parent.map { [$0] } ?? [], payload: payload, date: Date())
        try write(revision, root: root, kind: kind); return revision.id
    }
    static func stableID(_ string: String) -> UUID {
        let hex = SHA256.hash(data: Data(string.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let a = Array(hex)
        return UUID(uuidString: String(a[0..<8]) + "-" + String(a[8..<12]) + "-" + String(a[12..<16]) + "-" + String(a[16..<20]) + "-" + String(a[20..<32]))!
    }
    static func objects(root: URL, kind: String, reconcile: Bool = true) throws -> [UUID: LibraryObject] {
        let base = root.appendingPathComponent("revisions").appendingPathComponent(kind)
        guard FileManager.default.fileExists(atPath: base.path) else { return [:] }
        try ready(root); try ready(root.appendingPathComponent("revisions")); try ready(base)
        var result: [UUID: LibraryObject] = [:]
        var pendingCopies: [LibraryRevision] = []
        for folder in try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            try Task.checkCancellation(); try ready(folder)
            if folder.lastPathComponent.hasPrefix(".") { continue }
            guard let id = UUID(uuidString: folder.lastPathComponent), try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw LibraryStorageError.unrecognized }
            var records: [UUID: LibraryRevision] = [:]
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                if url.lastPathComponent.hasPrefix(".") { // iCloud placeholders must not look like missing revisions.
                    if url.pathExtension == "icloud" { try ready(url) }
                    continue
                }
                guard url.pathExtension == "json" else { throw LibraryStorageError.unrecognized }
                let record = try JSONDecoder().decode(LibraryRevision.self, from: read(url))
                guard record.version == 1, record.objectID == id, url.deletingPathExtension().lastPathComponent == record.id.uuidString,
                      Set(record.parents).count == record.parents.count, !record.parents.contains(record.id) else { throw LibraryStorageError.unrecognized }
                if let payload = record.payload { try validate(payload, kind: kind, id: id) }
                records[record.id] = record
            }
            guard !records.isEmpty else { continue }
            let parents = Set(records.values.flatMap(\.parents))
            // Cloud delivery is not ordered. Wait for ancestors before deciding
            // that a revision is a concurrent edit or a deletion.
            guard parents.isSubset(of: Set(records.keys)) else { throw LibraryStorageError.downloading }
            var remaining = records.mapValues { $0.parents.count }
            var children: [UUID: [UUID]] = [:]
            for record in records.values { for parent in record.parents { children[parent, default: []].append(record.id) } }
            var queue = records.values.filter { $0.parents.isEmpty }.map(\.id), visited = 0
            while visited < queue.count {
                let node = queue[visited]; visited += 1
                for child in children[node] ?? [] {
                    remaining[child, default: 0] -= 1
                    if remaining[child] == 0 { queue.append(child) }
                }
            }
            guard visited == records.count else { throw LibraryStorageError.unrecognized }
            let heads = records.values.filter { !parents.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
            guard let first = heads.first else { throw LibraryStorageError.unrecognized }
            let winner = heads.first(where: { $0.payload == nil }) ?? first
            if heads.count == 1 || !reconcile {
                result[id] = LibraryObject(id: id, revision: winner.id, payload: winner.payload)
                continue
            }
            // Save every distinct concurrent edit before acknowledging its head.
            // IDs and merge bytes are deterministic on every device, making
            // retries and simultaneous reconciliation idempotent.
            var seen = Set<Data>(); if let payload = winner.payload { seen.insert(payload) }
            for head in heads where head.id != winner.id {
                guard let payload = head.payload, seen.insert(payload).inserted else { continue }
                let copyID = stableID("copy:\(kind):\(id):\(head.id)")
                let copy = try conflictPayload(payload, kind: kind, id: copyID, source: id)
                let revision = LibraryRevision(id: stableID("initial:\(copyID)"), objectID: copyID, parents: [], payload: copy, date: head.date)
                try write(revision, root: root, kind: kind)
                pendingCopies.append(revision)
            }
            let parentIDs = heads.map(\.id).sorted { $0.uuidString < $1.uuidString }
            let merged = LibraryRevision(id: stableID("merge:\(kind):\(id):" + parentIDs.map(\.uuidString).joined(separator: ":")),
                objectID: id, parents: parentIDs, payload: winner.payload, date: heads.map(\.date).max()!)
            try write(merged, root: root, kind: kind)
            result[id] = LibraryObject(id: id, revision: merged.id, payload: merged.payload)
        }
        for copy in pendingCopies where result[copy.objectID] == nil {
            result[copy.objectID] = LibraryObject(id: copy.objectID, revision: copy.id, payload: copy.payload)
        }
        return result
    }
    static func validate(_ payload: Data, kind: String, id: UUID) throws {
        if kind == "notes" {
            let note = try JSONDecoder().decode(NoteDocument.self, from: payload)
            try note.validate(); guard note.id == id else { throw LibraryStorageError.unrecognized }
        } else {
            let value = try JSONDecoder().decode(LibraryCollection.self, from: payload)
            guard value.id == id, !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryStorageError.unrecognized }
        }
    }
    static func conflictPayload(_ data: Data, kind: String, id: UUID, source: UUID) throws -> Data {
        if kind == "notes" {
            var note = try JSONDecoder().decode(NoteDocument.self, from: data)
            note.id = id; note.conflictOf = source; note.isShelved = true
            return try encode(note)
        } else {
            var collection = try JSONDecoder().decode(LibraryCollection.self, from: data)
            collection.id = id; collection.conflictOf = source
            return try encode(collection)
        }
    }
    static func snapshot(_ root: URL, reconcile: Bool = true) throws -> LibrarySnapshot {
        let manifest = try manifest(at: root)
        // The manifest can arrive before its initial files. Do not open that
        // partial download as a new, empty library.
        for path in manifest.baseline {
            let url = root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                throw LibraryStorageError.downloading
            }
            try ready(url)
        }
        return try LibrarySnapshot(notes: objects(root: root, kind: "notes", reconcile: reconcile), collections: objects(root: root, kind: "collections", reconcile: reconcile))
    }
    static func pendingResources(_ snapshot: LibrarySnapshot, root: URL) throws -> Set<UUID> {
        var pending = Set<UUID>()
        let assets = root.appendingPathComponent("assets")
        for directory in [assets, assets.appendingPathComponent("files")] {
            if FileManager.default.fileExists(atPath: directory.path) { try ready(directory) }
        }
        for object in snapshot.notes.values {
            guard let payload = object.payload else { continue }
            let note = try JSONDecoder().decode(NoteDocument.self, from: payload)
            for block in note.content.blocks {
                var urls: [URL] = []
                if let image = block.image, !image.isRemotePlaceholder {
                    urls += [assets.appendingPathComponent(image.id.uuidString + ".png"), assets.appendingPathComponent(image.id.uuidString + ".original")]
                }
                if let audio = block.audio { urls.append(assets.appendingPathComponent(audio.id.uuidString + "." + audio.fileExtension)) }
                if let video = block.video { urls += [assets.appendingPathComponent(video.id.uuidString + "." + video.fileExtension), assets.appendingPathComponent(video.id.uuidString + ".poster.jpg")] }
                if let attachment = block.attachment { urls.append(attachment.url(in: assets.appendingPathComponent("files"))) }
                for url in urls {
                    do { try ready(url) }
                    catch LibraryStorageError.unsafePath { throw LibraryStorageError.unsafePath }
                    catch {
                        pending.insert(note.id)
                        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                    }
                }
            }
        }
        return pending
    }

    static func desktop(_ note: NoteDocument, at path: LibraryPath) throws {
        let directory = path.desktopDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(note.id.uuidString + ".json")
        let data = try encode(LibraryDesktopState(note))
        if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
    }
    static func withDesktop(_ note: NoteDocument, at path: LibraryPath) throws -> NoteDocument {
        var note = note
        let url = path.desktopDirectory.appendingPathComponent(note.id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: url.path) {
            try JSONDecoder().decode(LibraryDesktopState.self, from: Data(contentsOf: url)).apply(to: &note)
        }
        return note
    }
}

nonisolated struct LibraryCollection: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var members: Set<UUID> = []
    var conflictOf: UUID?
    private enum CodingKeys: String, CodingKey { case id, name, members, conflictOf }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(name, forKey: .name)
        try values.encode(members.sorted { $0.uuidString < $1.uuidString }, forKey: .members)
        try values.encodeIfPresent(conflictOf, forKey: .conflictOf)
    }
}

@MainActor enum LibraryFileActivity {
    static var exports = 0
    static var imports = 0
}
