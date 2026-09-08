import Foundation
import Testing
@testable import FoldpinCore

@Test @MainActor func libraryNotesPersistIndependentContentAndWindowState() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = NoteLibrary(directory: directory)
    let first = try #require(library.entries.first)
    let second = try #require(library.createNote())
    #expect(first.id != second.id && first.store !== second.store)
    #expect(first.store.document.text.isEmpty && second.store.document.text.isEmpty)
    first.store.edit("第一张 🌿\n独立保存")
    first.store.setPinned(true); first.store.setCollapsed(true); first.store.setShelved(true)
    first.store.setFrame(CGRect(x: -500, y: 120, width: 420, height: 500))
    second.store.edit("second note")
    second.store.setFrame(CGRect(x: 80, y: 200, width: 360, height: 340))
    #expect(first.store.flush() && second.store.flush())
    let reopened = NoteLibrary(directory: directory)
    #expect(reopened.entries.count == 2 && reopened.failure == nil)
    #expect(reopened.entry(first.id)?.store.document == first.store.document)
    #expect(reopened.entry(second.id)?.store.document == second.store.document)
    #expect(first.store.file.assetsURL == second.store.file.assetsURL)
    // Retrying the index while an editor is dirty preserves its live store.
    second.store.edit("unsaved latest text")
    library.reload()
    #expect(library.entry(second.id)?.store === second.store)
    #expect(second.store.isDirty && second.store.document.text == "unsaved latest text")
    #expect(second.store.flush())
}

@Test @MainActor func libraryMigratesLegacyBytesAndSharesExistingAssets() throws {
    for version in [1, 2] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = NoteFile(url: directory.appendingPathComponent("note.json"))
        var document = NoteDocument()
        document.text = "已有纸片\n保留内容"
        document.isCollapsed = true; document.isPinned = true; document.isShelved = true
        let asset = NoteImage(id: UUID(), name: "test.png", pixelWidth: 20, pixelHeight: 20)
        if version == 2 {
            try FileManager.default.createDirectory(at: legacy.assetsURL, withIntermediateDirectories: true)
            for original in [false, true] { try Data("image fixture".utf8).write(to: legacy.imageURL(asset.id, original: original)) }
            document.content.blocks.append(NoteBlock(kind: .image, image: asset))
        }
        try legacy.save(document)
        if version == 1 {
            var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: legacy.url)) as? [String: Any])
            raw["version"] = 1; raw["text"] = document.text; raw.removeValue(forKey: "content")
            try JSONSerialization.data(withJSONObject: raw).write(to: legacy.url)
        }
        let original = try Data(contentsOf: legacy.url)
        let library = NoteLibrary(directory: directory)
        let entry = try #require(library.entry(document.id))
        #expect(library.failure == nil && library.entries.count == 1)
        #expect(entry.store.document.text == document.text && entry.store.document.isCollapsed)
        #expect(entry.store.document.isPinned && entry.store.document.isShelved)
        #expect(try Data(contentsOf: legacy.url) == original)
        let backup = directory.appendingPathComponent("backups/legacy-note-\(document.id.uuidString).json")
        #expect(try Data(contentsOf: backup) == original)
        if version == 2 { #expect(entry.store.file.imageURL(asset.id) == legacy.imageURL(asset.id)) }
        entry.store.edit("new text after migration")
        #expect(entry.store.flush())
        // Simulate interruption after writing the new note but before its marker.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("library-migration.json"))
        let retry = NoteLibrary(directory: directory)
        #expect(retry.entry(document.id)?.store.document.text == "new text after migration")
        #expect(retry.entries.count == 1)
        #expect(try Data(contentsOf: backup) == original)
    }
}

@Test @MainActor func libraryRefusesMigrationWhenBackupCannotBeCreated() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let legacy = NoteFile(url: directory.appendingPathComponent("note.json"))
    var document = NoteDocument(); document.text = "do not overwrite"
    try legacy.save(document)
    let original = try Data(contentsOf: legacy.url)
    let backups = directory.appendingPathComponent("backups")
    try Data("blocked".utf8).write(to: backups)
    let library = NoteLibrary(directory: directory)
    #expect(library.failure != nil && library.entries.isEmpty && library.createNote() == nil)
    #expect(try Data(contentsOf: legacy.url) == original)
    try FileManager.default.removeItem(at: backups)
    library.reload()
    #expect(library.failure == nil && library.entries.first?.store.document == document)
}

@Test @MainActor func libraryCorruptLegacyAndDirectoryFailureKeepOriginals() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let legacy = directory.appendingPathComponent("note.json")
    let original = Data("{ invalid json".utf8)
    try original.write(to: legacy)
    let library = NoteLibrary(directory: directory)
    #expect(library.failure != nil && library.entries.isEmpty)
    #expect(library.createNote() == nil)
    #expect(try Data(contentsOf: legacy) == original)
    let blocked = NoteLibrary(directory: legacy)
    #expect(blocked.failure != nil && blocked.createNote() == nil)
    #expect(try Data(contentsOf: legacy) == original)
}

@Test @MainActor func libraryIsolatesCorruptNoteAndRejectsIdentityMismatch() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = NoteLibrary(directory: directory)
    let first = try #require(library.entries.first)
    let second = try #require(library.createNote())
    try Data("corrupt".utf8).write(to: first.store.file.url)
    let reopened = NoteLibrary(directory: directory)
    let bad = try #require(reopened.entry(first.id))
    #expect(reopened.failure == nil && reopened.entries.count == 2)
    #expect(bad.store.loadError != nil && !bad.store.flush())
    #expect(reopened.entry(second.id)?.store.loadError == nil && reopened.createNote() != nil)
    #expect(try String(contentsOf: bad.store.file.url, encoding: .utf8) == "corrupt")
    let file = second.store.file
    let original = try Data(contentsOf: file.url)
    #expect(throws: NoteFileError.self) { try file.save(NoteDocument()) }
    #expect(try Data(contentsOf: file.url) == original)
    try original.write(to: bad.store.file.url)
    #expect(throws: NoteFileError.self) { try bad.store.file.load() }
    try FileManager.default.removeItem(at: file.url)
    #expect(throws: (any Error).self) { try file.load() }
}

@Test @MainActor func libraryFailedCreationDoesNotAddAnUnsavedNote() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = NoteLibrary(directory: directory)
    let existing = try #require(library.entries.first)
    let notes = directory.appendingPathComponent("notes")
    let retained = directory.appendingPathComponent("retained-notes")
    try FileManager.default.moveItem(at: notes, to: retained)
    try Data("not a directory".utf8).write(to: notes)
    #expect(library.createNote() == nil && library.failure != nil)
    #expect(library.entries.count == 1 && library.entries[0].store === existing.store)
    try FileManager.default.removeItem(at: notes)
    try FileManager.default.moveItem(at: retained, to: notes)
    library.reload()
    #expect(library.failure == nil && library.createNote() != nil)
}
