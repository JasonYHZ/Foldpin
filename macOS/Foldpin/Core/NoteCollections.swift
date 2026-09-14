import Foundation
import Combine

/// Independent, versioned metadata. No body text, media bytes, or window state.
@MainActor
final class NoteCollections: ObservableObject {
    typealias Collection = LibraryCollection
    private struct File: Codable { var version = 1; var collections: [Collection] }
    @Published private(set) var collections: [Collection] = []
    @Published private(set) var error: Error?
    private(set) var unreadable = false
    private let initialURL: URL
    private let libraryPath: LibraryPath?
    private var revisions: [UUID: UUID] = [:]
    var url: URL { libraryPath?.root.appendingPathComponent("collections.json") ?? initialURL }
    init(directory: URL, libraryPath: LibraryPath? = nil) {
        initialURL = directory.appendingPathComponent("collections.json")
        self.libraryPath = libraryPath
        reload()
    }
    func reload() {
        do {
            if let path = libraryPath, path.manifest != nil {
                var next: [Collection] = []
                for object in path.snapshot.collections.values {
                    revisions[object.id] = object.revision
                    if let payload = object.payload { next.append(try JSONDecoder().decode(Collection.self, from: payload)) }
                }
                next.sort { $0.id.uuidString < $1.id.uuidString }
                if collections != next { collections = next }
                if unreadable { unreadable = false }
                if error != nil { error = nil }
                return
            }
            if FileManager.default.fileExists(atPath: url.path) {
                let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
                guard file.version == 1,
                      Set(file.collections.map(\.id)).count == file.collections.count,
                      file.collections.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                else { throw CocoaError(.fileReadCorruptFile) }
                collections = file.collections
            }
            unreadable = false; error = nil
        } catch { unreadable = true; self.error = error }
    }
    @discardableResult func create(_ name: String) -> UUID? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !collections.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        let value = Collection(name: name)
        return save(collections + [value]) ? value.id : nil
    }
    @discardableResult func rename(_ id: UUID, to name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !collections.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }),
              let index = collections.firstIndex(where: { $0.id == id }) else { return false }
        var next = collections; next[index].name = name
        return save(next)
    }
    @discardableResult func remove(_ id: UUID) -> Bool { save(collections.filter { $0.id != id }) }
    @discardableResult func setMembership(_ ids: Set<UUID>, collection: UUID, included: Bool) -> Bool {
        guard let index = collections.firstIndex(where: { $0.id == collection }) else { return false }
        var next = collections
        if included { next[index].members.formUnion(ids) } else { next[index].members.subtract(ids) }
        return save(next)
    }
    private func save(_ next: [Collection]) -> Bool {
        guard !unreadable else { return false }
        guard libraryPath?.writable != false else { error = LibraryStorageError.busy; return false }
        do {
            if let path = libraryPath, path.manifest != nil {
                try LibraryDisk.validateIdentity(path)
                let old = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) })
                let nextIDs = Set(next.map(\.id))
                for value in next where old[value.id] != value {
                    let data = try LibraryDisk.encode(value)
                    let revision = try LibraryDisk.save(data, id: value.id, parent: revisions[value.id], root: path.root, kind: "collections")
                    revisions[value.id] = revision
                    path.record(LibraryObject(id: value.id, revision: revision, payload: data), kind: "collections")
                }
                for value in collections where !nextIDs.contains(value.id) {
                    let revision = try LibraryDisk.save(nil, id: value.id, parent: revisions[value.id], root: path.root, kind: "collections")
                    revisions[value.id] = revision
                    path.record(LibraryObject(id: value.id, revision: revision, payload: nil), kind: "collections")
                }
                collections = next; error = nil; return true
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(File(collections: next)).write(to: url, options: .atomic)
            collections = next; error = nil
            return true
        } catch { self.error = error; return false }
    }
}
