import Foundation
import CryptoKit
import Testing
@testable import FoldpinCore

@MainActor private func storageFixture() throws -> (URL, NoteLibrary) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Foldpin-Storage-" + UUID().uuidString)
    let library = NoteLibrary(directory: root.appendingPathComponent("source"), localDirectory: root.appendingPathComponent("device-A"))
    let entry = try #require(library.entries.first)
    entry.store.edit("Original note"); #expect(entry.store.flush())
    return (root, library)
}
@MainActor private func moveFixture(_ root: URL, _ library: NoteLibrary) throws -> LibraryPreparedLocation {
    try LibraryRelocation.copy(source: library.directory, destination: root.appendingPathComponent("cloud"), journalURL: root.appendingPathComponent("local/move.json"))
}
private func exchange(_ source: URL, _ target: URL) throws {
    let base = source.appendingPathComponent("revisions").resolvingSymlinksInPath().standardizedFileURL
    let walker = try #require(FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]))
    for case let file as URL in walker {
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        let relative = String(file.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(base.path.count + 1))
        let destination = target.appendingPathComponent("revisions").appendingPathComponent(relative)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file, to: destination)
        }
    }
}
@Test @MainActor func libraryStorageMigrationPreservesFilesAndLivePaths() throws {
    let (root, library) = try storageFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let entry = try #require(library.entries.first)
    let retained = entry.store.file
    entry.store.setPinned(true); entry.store.setFrame(CGRect(x: 20, y: 30, width: 420, height: 330)); #expect(entry.store.flush())
    let original = try Data(contentsOf: retained.url)
    try Data("unknown safe file".utf8).write(to: library.directory.appendingPathComponent("extra.txt"))
    let prepared = try moveFixture(root, library)
    let path = LibraryPath(prepared.root, manifest: prepared.manifest, localDirectory: root.appendingPathComponent("device-A"))
    for note in prepared.desktops { try LibraryDisk.desktop(note, at: path) }
    library.relocate(to: prepared.root, manifest: prepared.manifest, snapshot: prepared.snapshot)
    #expect(retained.assetsURL == prepared.root.appendingPathComponent("assets"))
    #expect(entry.store.document.isPinned && entry.store.document.frame?.x == 20)
    entry.store.edit("After migration"); #expect(entry.store.flush())
    #expect(try Data(contentsOf: root.appendingPathComponent("source/notes/" + entry.id.uuidString + ".json")) == original)
    #expect(try Data(contentsOf: prepared.root.appendingPathComponent("extra.txt")) == Data("unknown safe file".utf8))
    #expect(library.entries.first?.store === entry.store)
    let other = NoteLibrary(directory: prepared.root, manifest: prepared.manifest, snapshot: try LibraryDisk.snapshot(prepared.root), localDirectory: root.appendingPathComponent("device-B"))
    let otherNote = try #require(other.entries.first?.store.document)
    #expect(otherNote.text == "After migration" && otherNote.isShelved && !otherNote.isPinned && otherNote.frame == nil)
    let before = try LibraryRelocation.inventory(prepared.root)
    entry.store.setFrame(CGRect(x: 100, y: 200, width: 440, height: 330)); #expect(entry.store.flush())
    #expect(try LibraryRelocation.inventory(prepared.root) == before)
}
@Test @MainActor func libraryStorageOfflineEditsKeepBothAndConverge() throws {
    let (root, old) = try storageFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let prepared = try moveFixture(root, old)
    let second = root.appendingPathComponent("cloud-B"); try FileManager.default.copyItem(at: prepared.root, to: second)
    let a = NoteLibrary(directory: prepared.root, manifest: prepared.manifest, snapshot: prepared.snapshot, localDirectory: root.appendingPathComponent("A"))
    let b = NoteLibrary(directory: second, manifest: prepared.manifest, snapshot: prepared.snapshot, localDirectory: root.appendingPathComponent("B"))
    let sa = try #require(a.entries.first?.store), sb = try #require(b.entries.first?.store)
    sa.edit("From device A"); sb.edit("From device B"); #expect(sa.flush() && sb.flush())
    try exchange(prepared.root, second); try exchange(second, prepared.root)
    let mergedA = try LibraryDisk.snapshot(prepared.root), mergedB = try LibraryDisk.snapshot(second)
    let textsA = try Set(mergedA.notes.values.compactMap(\.payload).map { try JSONDecoder().decode(NoteDocument.self, from: $0).text })
    #expect(textsA == ["From device A", "From device B"])
    #expect(Set(mergedA.notes.keys) == Set(mergedB.notes.keys))
    try exchange(prepared.root, second); try exchange(second, prepared.root)
    #expect(try LibraryDisk.snapshot(prepared.root).notes.count == 2)
    #expect(try LibraryDisk.snapshot(second).notes.count == 2)
    let copies = try mergedA.notes.values.compactMap(\.payload).map { try JSONDecoder().decode(NoteDocument.self, from: $0) }.filter { $0.conflictOf != nil }
    #expect(copies.count == 1)
}
@Test @MainActor func libraryStoragePermanentDeletionRetainsConcurrentEdit() throws {
    let (root, old) = try storageFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let prepared = try moveFixture(root, old)
    let bRoot = root.appendingPathComponent("B"); try FileManager.default.copyItem(at: prepared.root, to: bRoot)
    let a = NoteLibrary(directory: prepared.root, manifest: prepared.manifest, snapshot: prepared.snapshot, localDirectory: root.appendingPathComponent("A-state"))
    let b = NoteLibrary(directory: bRoot, manifest: prepared.manifest, snapshot: prepared.snapshot, localDirectory: root.appendingPathComponent("B-state"))
    let id = try #require(a.entries.first?.id)
    #expect(a.deleteNote(id)); try a.permanentlyDeleteNote(id)
    let store = try #require(b.entries.first?.store); store.edit("Offline edit survives"); #expect(store.flush())
    try exchange(bRoot, prepared.root)
    let snapshot = try LibraryDisk.snapshot(prepared.root)
    #expect(snapshot.notes[id]?.payload == nil)
    let documents = try snapshot.notes.values.compactMap(\.payload).map { try JSONDecoder().decode(NoteDocument.self, from: $0) }
    #expect(documents.count == 1 && documents.first?.text == "Offline edit survives" && documents.first?.conflictOf == id)
}
@Test @MainActor func libraryStorageCollectionsPreserveConcurrentMembership() throws {
    let (root, old) = try storageFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let legacy = NoteCollections(directory: old.directory)
    let id = try #require(legacy.create("Projects"))
    let prepared = try moveFixture(root, old)
    let bRoot = root.appendingPathComponent("B"); try FileManager.default.copyItem(at: prepared.root, to: bRoot)
    let aPath = LibraryPath(prepared.root, manifest: prepared.manifest, localDirectory: root.appendingPathComponent("A-state")); aPath.install(prepared.snapshot)
    let bPath = LibraryPath(bRoot, manifest: prepared.manifest, localDirectory: root.appendingPathComponent("B-state")); bPath.install(prepared.snapshot)
    let a = NoteCollections(directory: prepared.root, libraryPath: aPath), b = NoteCollections(directory: bRoot, libraryPath: bPath)
    let one = UUID(), two = UUID()
    #expect(a.setMembership([one], collection: id, included: true)); #expect(b.setMembership([two], collection: id, included: true))
    try exchange(prepared.root, bRoot); try exchange(bRoot, prepared.root)
    let sa = try LibraryDisk.snapshot(prepared.root), sb = try LibraryDisk.snapshot(bRoot)
    #expect(sa.collections.count == 2 && Set(sa.collections.keys) == Set(sb.collections.keys))
    let members = try sa.collections.values.compactMap(\.payload).map { try JSONDecoder().decode(LibraryCollection.self, from: $0).members }
    #expect(members.contains([one]) && members.contains([two]))
}
@Test @MainActor func libraryStorageRejectsUnsafeAndIncompleteMigration() throws {
    let (root, library) = try storageFixture(); defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: LibraryStorageError.self) {
        _ = try LibraryRelocation.copy(source: library.directory, destination: library.directory.appendingPathComponent("child"), journalURL: root.appendingPathComponent("journal"))
    }
    try FileManager.default.createSymbolicLink(at: library.directory.appendingPathComponent("escape"), withDestinationURL: root)
    #expect(throws: LibraryStorageError.self) { _ = try moveFixture(root, library) }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cloud").path))
    try FileManager.default.removeItem(at: library.directory.appendingPathComponent("escape"))
    let entry = try #require(library.entries.first)
    var note = entry.store.document
    note.content.blocks.append(NoteBlock(kind: .audio, audio: NoteAudio(name: "Missing", fileExtension: "m4a", duration: 1)))
    try LibraryDisk.encode(note).write(to: entry.store.file.url)
    #expect(throws: (any Error).self) { _ = try moveFixture(root, library) }
    #expect(FileManager.default.fileExists(atPath: entry.store.file.url.path))
}
@Test @MainActor func libraryStoragePendingAncestorsNeverBecomeEmptyLibrary() throws {
    let (root, old) = try storageFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let prepared = try moveFixture(root, old)
    let id = UUID(), missing = UUID()
    let note = NoteDocument()
    let record = LibraryRevision(id: UUID(), objectID: note.id, parents: [missing], payload: try LibraryDisk.encode(note), date: Date())
    _ = id
    try LibraryDisk.write(record, root: prepared.root, kind: "notes")
    #expect(throws: LibraryStorageError.self) { _ = try LibraryDisk.snapshot(prepared.root) }
}

@Test @MainActor func libraryStorageInventoryCopiesRelativePaths() throws {
    let (root, library) = try storageFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("copy")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let before = try LibraryRelocation.inventory(library.directory, copyingTo: target)
    let copied = try LibraryRelocation.inventory(target)
    #expect(copied == before)
    #expect(try LibraryRelocation.inventory(library.directory) == before)
}

@Test @MainActor func libraryStorageResumeChecksBothSourceAndCompletedTarget() throws {
    let (root, library) = try storageFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let first = try moveFixture(root, library)
    let journal = try JSONDecoder().decode(LibraryMoveJournal.self, from: Data(contentsOf: root.appendingPathComponent("local/move.json")))
    #expect(journal.source == library.directory)
    #expect(journal.destination == first.root)
    let sourceDigest = Data(SHA256.hash(data: try LibraryDisk.encode(LibraryRelocation.inventory(library.directory))))
    let targetDigest = Data(SHA256.hash(data: try LibraryDisk.encode(LibraryRelocation.inventory(first.root))))
    #expect(journal.sourceDigest == sourceDigest)
    #expect(journal.destinationDigest == targetDigest)
    let second = try moveFixture(root, library)
    #expect(first.manifest == second.manifest)
    let targetBytes = try LibraryRelocation.inventory(first.root)
    let store = try #require(library.entries.first?.store)
    store.edit("Source changed after interrupted switch"); #expect(store.flush())
    #expect(throws: LibraryStorageError.self) { _ = try moveFixture(root, library) }
    #expect(try LibraryRelocation.inventory(first.root) == targetBytes)
}

@Test @MainActor func libraryStorageManifestArrivingFirstWaitsForInitialRevisions() throws {
    let (root, library) = try storageFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let prepared = try moveFixture(root, library)
    let partial = root.appendingPathComponent("partial")
    try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: prepared.root.appendingPathComponent("library.json"), to: partial.appendingPathComponent("library.json"))
    #expect(throws: LibraryStorageError.self) { _ = try LibraryDisk.snapshot(partial) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: partial.path) == ["library.json"])
    try exchange(prepared.root, partial)
    #expect(try LibraryDisk.snapshot(partial).notes.count == 1)
}

@Test @MainActor func libraryStorageSuspensionBlocksRetainedFilesAndNewNotes() throws {
    let (root, old) = try storageFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let prepared = try moveFixture(root, old)
    old.relocate(to: prepared.root, manifest: prepared.manifest, snapshot: prepared.snapshot)
    let store = try #require(old.entries.first?.store)
    let retained = store.file, before = try LibraryRelocation.inventory(prepared.root)
    old.setSuspended(true)
    #expect(!old.canCreate)
    store.edit("Late callback must not write")
    #expect(throws: LibraryStorageError.self) { try retained.save(store.document) }
    #expect(try LibraryRelocation.inventory(prepared.root) == before)
    old.setSuspended(false)
    store.edit("Editing resumes"); #expect(store.flush())
    #expect(try retained.load().text == "Editing resumes")
}

@Test @MainActor func libraryStorageCancellationKeepsSourceAndRemovesOwnStaging() async throws {
    let (root, old) = try storageFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let source = old.directory, destination = root.appendingPathComponent("cancelled")
    let before = try LibraryRelocation.inventory(source)
    let worker = Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        return try LibraryRelocation.copy(source: source, destination: destination, journalURL: root.appendingPathComponent("journal"))
    }
    do { _ = try await worker.value; Issue.record("Cancelled migration completed") } catch is CancellationError {} catch { Issue.record(error) }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(try LibraryRelocation.inventory(source) == before)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".foldpin-move-") })
}

@Test @MainActor func libraryStorageReadOnlyProbeNeverMergesConflictFiles() throws {
    let (root, old) = try storageFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let prepared = try moveFixture(root, old)
    let object = try #require(prepared.snapshot.notes.values.first)
    var note = try JSONDecoder().decode(NoteDocument.self, from: #require(object.payload))
    note.content = NoteContent(plainText: "A")
    _ = try LibraryDisk.save(LibraryDisk.encode(note), id: note.id, parent: object.revision, root: prepared.root, kind: "notes")
    note.content = NoteContent(plainText: "B")
    _ = try LibraryDisk.save(LibraryDisk.encode(note), id: note.id, parent: object.revision, root: prepared.root, kind: "notes")
    let before = try LibraryRelocation.inventory(prepared.root)
    _ = try LibraryDisk.snapshot(prepared.root, reconcile: false)
    #expect(try LibraryRelocation.inventory(prepared.root) == before)
    #expect(try LibraryDisk.snapshot(prepared.root).notes.count == 2)
}

@Test @MainActor func libraryStorageReplacedManifestCannotReceiveOldSessionWrites() throws {
    let (root, old) = try storageFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let prepared = try moveFixture(root, old)
    old.relocate(to: prepared.root, manifest: prepared.manifest, snapshot: prepared.snapshot)
    let store = try #require(old.entries.first?.store)
    var replacement = prepared.manifest; replacement.id = UUID()
    try LibraryDisk.encode(replacement).write(to: prepared.root.appendingPathComponent("library.json"), options: .atomic)
    let before = try LibraryRelocation.inventory(prepared.root)
    store.edit("Must remain unsaved")
    #expect(!store.flush() && store.isDirty)
    #expect(try LibraryRelocation.inventory(prepared.root) == before)
}

@Test @MainActor func libraryStorageRejectsRevisionCyclesWithoutLosingKnownRoot() throws {
    let (root, old) = try storageFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let prepared = try moveFixture(root, old)
    let object = try #require(prepared.snapshot.notes.values.first)
    let a = UUID(), b = UUID()
    try LibraryDisk.write(LibraryRevision(id: a, objectID: object.id, parents: [b], payload: object.payload, date: Date()), root: prepared.root, kind: "notes")
    try LibraryDisk.write(LibraryRevision(id: b, objectID: object.id, parents: [a], payload: object.payload, date: Date()), root: prepared.root, kind: "notes")
    let before = try LibraryRelocation.inventory(prepared.root)
    #expect(throws: LibraryStorageError.self) { _ = try LibraryDisk.snapshot(prepared.root) }
    #expect(try LibraryRelocation.inventory(prepared.root) == before)
}
