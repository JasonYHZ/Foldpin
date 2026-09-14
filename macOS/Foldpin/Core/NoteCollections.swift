import Foundation
import Combine

/// Independent, versioned metadata. No body text, media bytes, or window state.
@MainActor
final class NoteCollections: ObservableObject {
    struct Collection: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var members: Set<UUID> = []
    }
    private struct File: Codable { var version = 1; var collections: [Collection] }
    @Published private(set) var collections: [Collection] = []
    @Published private(set) var error: Error?
    private(set) var unreadable = false
    let url: URL
    init(directory: URL) {
        url = directory.appendingPathComponent("collections.json")
        reload()
    }
    func reload() {
        do {
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
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(File(collections: next)).write(to: url, options: .atomic)
            collections = next; error = nil
            return true
        } catch { self.error = error; return false }
    }
}
