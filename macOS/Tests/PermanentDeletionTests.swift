import Foundation
import Testing
@testable import FoldpinCore

@Test @MainActor func permanentDeletionRemovesOnlyDeletedNotesAndCannotReappear() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = NoteLibrary(directory: root)
    let first = try #require(library.entries.first)
    first.store.edit("delete this")
    let second = try #require(library.createNote())
    second.store.edit("keep this")
    #expect(first.store.flush() && second.store.flush())
    #expect(throws: NoteFileError.self) { try library.permanentlyDeleteNote(second.id) }
    #expect(library.deleteNote(first.id))
    first.store.edit("queued before permanent deletion")
    try library.permanentlyDeleteNote(first.id)
    #expect(!FileManager.default.fileExists(atPath: first.store.file.url.path))
    #expect(library.restoreNote(first.id) == nil)
    first.store.edit("stale callback"); first.store.setDeletedAt(nil); first.store.reload()
    #expect(!first.store.flush())
    try await Task.sleep(for: .milliseconds(600))
    library.reload()
    #expect(library.entries.map(\.id) == [second.id] && library.deletedEntries.isEmpty)
    #expect(NoteLibrary(directory: root).entries.map(\.id) == [second.id])
    #expect(library.deleteNote(second.id))
    try library.permanentlyDeleteNote(second.id)
    library.reload()
    let reopened = NoteLibrary(directory: root)
    #expect(reopened.entries.isEmpty && reopened.deletedEntries.isEmpty)
    #expect(reopened.createNote() != nil)
}

@Test @MainActor func permanentDeletionFailureRetainsRecoveryAndSharedAssets() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = NoteLibrary(directory: root)
    let first = try #require(library.entries.first)
    let file = root.appendingPathComponent("sample.txt")
    try Data("shared bytes".utf8).write(to: file)
    let asset = try #require(NoteAttachmentImporter.prepare(urls: [file], directory: first.store.file.assetsURL.appendingPathComponent("files")).first)
    first.store.edit(NoteContent(blocks: [NoteBlock(kind: .file, attachment: asset)]))
    let duplicate = try #require(library.duplicateNote(first.id))
    #expect(library.deleteNote(first.id))
    // A replaced on-disk record that is no longer deleted must not be unlinked.
    var external = first.store.document; external.deletedAt = nil
    try first.store.file.save(external)
    #expect(throws: NoteFileError.self) { try library.permanentlyDeleteNote(first.id) }
    #expect(library.deletedEntries.contains { $0.id == first.id })
    #expect(first.store.loadError == nil)
    try first.store.file.save(first.store.document)
    try library.permanentlyDeleteNote(first.id)
    #expect(try Data(contentsOf: duplicate.store.file.attachmentURL(asset)) == Data("shared bytes".utf8))
    #expect(duplicate.store.flush())
    #expect(throws: NoteFileError.self) { try library.permanentlyDeleteNote(first.id) }
}
