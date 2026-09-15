import Combine
import Foundation

/// The directory is the index: each UUID file is independently recoverable.
/// Assets stay in the shared UUID asset directory, including legacy images.
@MainActor
final class NoteLibrary: ObservableObject {
    struct Entry: Identifiable {
        let id: UUID
        let store: NoteStore
    }
    private struct Migration: Codable {
        var version = 1
        let legacyID: UUID
    }
    private let createsInitialNote: Bool
    let path: LibraryPath
    var directory: URL { path.root }
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var deletedEntries: [Entry] = []
    @Published private(set) var failure: Error?
    var canCreate: Bool { failure == nil && path.writable }
    private var notesURL: URL { directory.appendingPathComponent("notes", isDirectory: true) }
    private var assetsURL: URL { directory.appendingPathComponent("assets", isDirectory: true) }

    init(directory: URL? = nil, manifest: LibraryManifest? = nil, snapshot: LibrarySnapshot? = nil,
         localDirectory: URL? = nil, initialError: Error? = nil, createsInitialNote: Bool = true) {
        self.createsInitialNote = createsInitialNote
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        path = LibraryPath(directory ?? support.appendingPathComponent("Foldpin"), manifest: manifest,
            localDirectory: localDirectory ?? support.appendingPathComponent("FoldpinLocalState"))
        if let snapshot { path.install(snapshot) }
        if let initialError { failure = initialError } else { reload() }
    }
    func setSuspended(_ value: Bool) {
        path.setWritable(!value)
        for entry in entries + deletedEntries { entry.store.isLibrarySuspended = value }
        objectWillChange.send()
    }
    func apply(_ snapshot: LibrarySnapshot) {
        path.install(snapshot)
        let existing = Dictionary(uniqueKeysWithValues: (entries + deletedEntries).map { ($0.id, $0) })
        var current: [Entry] = []
        for object in snapshot.notes.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            if object.payload == nil {
                if let old = existing[object.id], !old.store.isDirty { old.store.invalidateAfterPermanentDeletion() }
                continue
            }
            if let old = existing[object.id] {
                if !old.store.isDirty { old.store.acceptExternalRevision() }
                current.append(old)
            } else { current.append(Entry(id: object.id, store: NoteStore(file: file(for: object.id)))) }
        }
        // Never discard an unsaved local branch because a remote tombstone arrived.
        for old in existing.values where old.store.isDirty && !current.contains(where: { $0.id == old.id }) { current.append(old) }
        let active = current.filter { $0.store.document.deletedAt == nil }
        let deleted = current.filter { $0.store.document.deletedAt != nil }.sorted { $0.store.document.deletedAt! > $1.store.document.deletedAt! }
        if entries.map(\.id) != active.map(\.id) { entries = active }
        if deletedEntries.map(\.id) != deleted.map(\.id) { deletedEntries = deleted }
        if failure != nil { failure = nil }
    }
    func relocate(to directory: URL, manifest: LibraryManifest, snapshot: LibrarySnapshot) {
        path.relocate(to: directory, manifest: manifest)
        apply(snapshot)
    }

    func reload() {
        if path.manifest != nil { apply(path.snapshot); return }
        do {
            try FileManager.default.createDirectory(at: notesURL, withIntermediateDirectories: true)
            try migrateLegacyNote()
            let files = try FileManager.default.contentsOfDirectory(at: notesURL, includingPropertiesForKeys: [.isRegularFileKey])
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            let previousEntries = entries + deletedEntries
            let old = Dictionary(uniqueKeysWithValues: previousEntries.map { ($0.id, $0) })
            var loaded: [Entry] = []
            var seen = Set<UUID>()
            for url in files {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), seen.insert(id).inserted else { throw NoteFileError.invalidContent }
                // A retry must not discard a live editor's store or pending edits.
                loaded.append(old[id] ?? Entry(id: id, store: NoteStore(file: NoteFile(url: url, assetDirectory: assetsURL, expectedID: id, libraryPath: path))))
            }
            for entry in previousEntries where !loaded.contains(where: { $0.id == entry.id }) { loaded.append(entry) }
            entries = loaded.filter { $0.store.document.deletedAt == nil }
            deletedEntries = loaded.filter { $0.store.document.deletedAt != nil }
                .sorted { $0.store.document.deletedAt! > $1.store.document.deletedAt! }
            failure = nil
            if !createsInitialNote && entries.isEmpty && deletedEntries.isEmpty {
                let marker = directory.appendingPathComponent("library-kept-empty")
                if !FileManager.default.fileExists(atPath: marker.path) { try Data().write(to: marker, options: .atomic) }
            }
            if createsInitialNote && entries.isEmpty && deletedEntries.isEmpty && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("library-kept-empty").path) { _ = createNote() }
        } catch { failure = error }
    }

    @discardableResult func createNote() -> Entry? {
        persistNewNote(NoteDocument())
    }

    func importDocument(_ document: NoteDocument) throws -> Entry {
        guard canCreate else { throw failure ?? LibraryStorageError.busy }
        if let existing = (entries + deletedEntries).first(where: { $0.id == document.id }) { return existing }
        let destination = file(for: document.id)
        if path.snapshot.notes[document.id] == nil && !FileManager.default.fileExists(atPath: destination.url.path) {
            try destination.save(document)
        }
        let store = NoteStore(file: destination)
        if store.loadError != nil { throw NoteFileError.invalidContent }
        let entry = Entry(id: document.id, store: store)
        if store.document.deletedAt == nil { entries.append(entry) } else { deletedEntries.append(entry) }
        return entry
    }

    @discardableResult func duplicateNote(_ id: UUID) -> Entry? {
        guard canCreate, let source = entry(id), source.store.loadError == nil, source.store.flush() else { return nil }
        var document = source.store.document
        document.id = UUID()
        document.conflictOf = nil
        document.content.blocks = document.content.blocks.map { block in
            var copy = block; copy.id = UUID(); return copy
        }
        document.isShelved = false
        document.deletedAt = nil
        document.modifiedAt = Date()
        document.createdAt = document.modifiedAt
        if var frame = document.frame {
            frame.x += 24; frame.y -= 24
            document.frame = frame
        }
        return persistNewNote(document)
    }

    private func persistNewNote(_ value: NoteDocument) -> Entry? {
        guard canCreate else { return nil }
        do {
            var document = value
            while FileManager.default.fileExists(atPath: file(for: document.id).url.path) || path.snapshot.notes[document.id] != nil { document.id = UUID() }
            let file = file(for: document.id)
            // Persist first. A failed creation never becomes an apparently saved window.
            try file.save(document)
            let entry = Entry(id: document.id, store: NoteStore(file: file))
            guard entry.store.loadError == nil else { throw NoteFileError.invalidContent }
            entries.append(entry)
            return entry
        } catch { failure = error; return nil }
    }

    func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }

    @discardableResult func deleteNote(_ id: UUID) -> Bool {
        guard let entry = entry(id), entry.store.setDeletedAt(Date()) else { return false }
        entries.removeAll { $0.id == id }
        deletedEntries.insert(entry, at: 0)
        return true
    }

    @discardableResult func restoreNote(_ id: UUID, toShelf: Bool = false) -> Entry? {
        guard let entry = deletedEntries.first(where: { $0.id == id }) else { return nil }
        guard toShelf ? entry.store.restoreToShelf() : entry.store.setDeletedAt(nil) else { return nil }
        deletedEntries.removeAll { $0.id == id }
        entries.append(entry)
        return entry
    }

    /// Only a confirmed UUID in Recently Deleted is eligible. Unlink the
    /// document first; a failure keeps its store and restore path intact.
    func permanentlyDeleteNote(_ id: UUID) throws {
        guard failure == nil, let entry = deletedEntries.first(where: { $0.id == id }),
              entry.store.document.deletedAt != nil, entry.store.loadError == nil else { throw NoteFileError.invalidContent }
        if path.manifest != nil {
            guard path.writable else { throw LibraryStorageError.busy }
            try LibraryDisk.validateIdentity(path)
            let revision = try LibraryDisk.save(nil, id: id, parent: entry.store.file.cursor.revision, root: directory, kind: "notes")
            path.record(LibraryObject(id: id, revision: revision, payload: nil), kind: "notes")
            entry.store.invalidateAfterPermanentDeletion(); deletedEntries.removeAll { $0.id == id }
            return
        }
        let url = entry.store.file.url
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true,
              try entry.store.file.load().deletedAt != nil else { throw NoteFileError.invalidContent }
        // Once the user deliberately empties the library, startup must not
        // manufacture a replacement blank note.
        let marker = directory.appendingPathComponent("library-kept-empty")
        if !FileManager.default.fileExists(atPath: marker.path) { try Data().write(to: marker, options: .atomic) }
        try FileManager.default.removeItem(at: url)
        entry.store.invalidateAfterPermanentDeletion()
        deletedEntries.removeAll { $0.id == id }
        // Shared assets can belong to surviving notes, clipboard references or
        // their undo histories. Do not sweep that directory during note deletion.
    }

    func message(bundle: Bundle) -> String? {
        guard let failure else { return nil }
        return String(localized: "Could not open the note library. Existing files have been kept.", bundle: bundle)
            + "\n" + ((failure as? LibraryStorageError)?.description(bundle: bundle) ?? (failure as? NoteFileError)?.description(bundle: bundle) ?? failure.localizedDescription)
    }

    private func file(for id: UUID) -> NoteFile {
        NoteFile(url: notesURL.appendingPathComponent(id.uuidString + ".json"), assetDirectory: assetsURL, expectedID: id, libraryPath: path)
    }

    private func migrateLegacyNote() throws {
        let marker = directory.appendingPathComponent("library-migration.json")
        if FileManager.default.fileExists(atPath: marker.path) {
            let migration = try JSONDecoder().decode(Migration.self, from: Data(contentsOf: marker))
            guard migration.version == 1 else { throw NoteFileError.unsupportedVersion }
            return
        }
        let legacy = directory.appendingPathComponent("note.json")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        let original = try Data(contentsOf: legacy)
        let document = try NoteFile(url: legacy).load()
        let backups = directory.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let backup = backups.appendingPathComponent("legacy-note-\(document.id.uuidString).json")
        if FileManager.default.fileExists(atPath: backup.path) {
            guard try Data(contentsOf: backup) == original else { throw NoteFileError.invalidContent }
        } else { try original.write(to: backup, options: .withoutOverwriting) }
        let destination = file(for: document.id)
        if FileManager.default.fileExists(atPath: destination.url.path) {
            // A previous attempt may have saved the note before writing its marker.
            // Never overwrite subsequent edits with the legacy snapshot.
            _ = try destination.load()
        } else { try destination.save(document) }
        let data = try JSONEncoder().encode(Migration(legacyID: document.id))
        try data.write(to: marker, options: .atomic)
    }
}
