import Foundation
import Testing
@testable import FoldpinCore

@Test @MainActor func collectionMembershipSurvivesDeletionAndCollectionRemovalKeepsNotes() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = NoteLibrary(directory: directory)
    let entry = try #require(library.entries.first)
    entry.store.edit("Keep the original body")
    let modified = entry.store.document.modifiedAt
    #expect(entry.store.setFavorite(true))
    #expect(entry.store.document.modifiedAt == modified)
    let collections = NoteCollections(directory: directory)
    let id = try #require(collections.create(" Development "))
    #expect(collections.create("development") == nil)
    #expect(collections.create("   ") == nil)
    #expect(collections.setMembership([entry.id], collection: id, included: true))
    #expect(library.deleteNote(entry.id))
    let loaded = NoteCollections(directory: directory)
    #expect(loaded.collections.first?.members == [entry.id])
    let restored = try #require(library.restoreNote(entry.id, toShelf: true))
    #expect(restored.store.document.isShelved && restored.store.document.isFavorite)
    #expect(restored.store.document.modifiedAt == modified)
    #expect(loaded.remove(id))
    #expect(library.entry(entry.id)?.store.document.text == "Keep the original body")
}

@Test @MainActor func collectionFailurePreservesStateAndCorruptionBlocksWrites() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let collections = NoteCollections(directory: directory)
    let id = try #require(collections.create("Work"))
    let before = collections.collections
    try FileManager.default.removeItem(at: collections.url)
    try FileManager.default.createDirectory(at: collections.url, withIntermediateDirectories: false)
    #expect(!collections.rename(id, to: "Changed"))
    #expect(collections.collections == before && collections.error != nil)
    try FileManager.default.removeItem(at: collections.url)
    try Data("corrupt".utf8).write(to: collections.url)
    collections.reload()
    #expect(collections.unreadable && collections.create("New") == nil)
    #expect(try String(contentsOf: collections.url, encoding: .utf8) == "corrupt")
}

@Test @MainActor func favoriteAndRestoreFailuresRetainOriginalMetadata() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = NoteLibrary(directory: directory)
    let entry = try #require(library.entries.first)
    #expect(library.deleteNote(entry.id))
    let before = entry.store.document
    try FileManager.default.removeItem(at: entry.store.file.url)
    try FileManager.default.createDirectory(at: entry.store.file.url, withIntermediateDirectories: false)
    #expect(library.restoreNote(entry.id, toShelf: true) == nil)
    #expect(entry.store.document == before)
    #expect(!entry.store.setFavorite(true))
    #expect(entry.store.document == before)
}
