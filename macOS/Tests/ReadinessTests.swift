import Foundation
import Testing
import ServiceManagement
@testable import FoldpinCore

@Suite @MainActor struct ReadinessTests {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Foldpin-readiness-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @Test func importPreservesEncodingAndRejectsOversize() throws {
        #expect(try MarkdownFileImport.decode(Data([0xef, 0xbb, 0xbf]) + Data("中文\nline".utf8)) == "中文\nline")
        #expect(try MarkdownFileImport.decode(Data([0xff, 0xfe]) + #require("中文".data(using: .utf16LittleEndian))) == "中文")
        #expect(throws: (any Error).self) { try MarkdownFileImport.decode(Data([0xff, 0xa0])) }
        #expect(throws: (any Error).self) { try MarkdownFileImport.decode(Data(repeating: 65, count: MarkdownFileImport.fileLimit + 1)) }
    }
    @Test func markdownRetainsUnsupportedContentAndNeverSchedulesRemoteImages() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = "---\ntitle: Preserve me\n---\n# Heading\n- [x] Done\n![alt](https://example.invalid/picture.png)\n```md\n![not a resource](missing.png)\n```"
        let result = try MarkdownFileImport.prepare(source: source, sourceURL: root.appendingPathComponent("test.md"), authorizedRoot: nil, staging: root.appendingPathComponent("stage"))
        #expect(result.content.blocks.first?.text.contains("title: Preserve me") == true)
        #expect(result.content.blocks.contains { $0.kind == .heading })
        #expect(result.content.blocks.contains { $0.kind == .task && $0.isChecked })
        #expect(result.content.plainText.contains("https://example.invalid/picture.png"))
        #expect(!result.content.blocks.contains { $0.image != nil })
        #expect(result.content.blocks.contains { $0.kind == .code && $0.text.contains("missing.png") })
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("stage").path))
    }
    @Test func markdownCopiesImagesAndFilesAndKeepsMissingLinksInOrder() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aH8QAAAAASUVORK5CYII="))
        try png.write(to: root.appendingPathComponent("image.png"))
        let file = Data("attachment source".utf8); try file.write(to: root.appendingPathComponent("doc.txt"))
        let result = try MarkdownFileImport.prepare(source: "Before\n![bad](missing.png)\nAfter\n![Caption](image.png)\n[File](doc.txt)", sourceURL: root.appendingPathComponent("test.md"), authorizedRoot: root, staging: root.appendingPathComponent("stage"))
        let text = result.content.plainText
        #expect(try #require(text.range(of: "Before")).lowerBound < #require(text.range(of: "missing.png")).lowerBound)
        #expect(try #require(text.range(of: "missing.png")).lowerBound < #require(text.range(of: "After")).lowerBound)
        let image = try #require(result.content.blocks.compactMap(\.image).first)
        #expect(image.caption == "Caption")
        #expect(try Data(contentsOf: root.appendingPathComponent("stage/\(image.id).original")) == png)
        let attachment = try #require(result.content.blocks.compactMap(\.attachment).first)
        #expect(try Data(contentsOf: attachment.url(in: root.appendingPathComponent("stage/files"))) == file)
        #expect(!result.warnings.isEmpty)
    }
    @Test func resourceAuthorizationRejectsTraversalAndSymlinks() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root.appendingPathComponent("safe.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.txt"), withDestinationURL: root.appendingPathComponent("safe.txt"))
        for reference in ["../outside.txt", "alias.txt", "https://example.invalid/test", "file:///etc/hosts"] {
            #expect(throws: (any Error).self) { try MarkdownFileImport.localResource(reference, source: root.appendingPathComponent("test.md"), authorizedRoot: root) }
        }
        #expect(try MarkdownFileImport.localResource("safe.txt", source: root.appendingPathComponent("test.md"), authorizedRoot: root).lastPathComponent == "safe.txt")
    }
    @Test func resourceBudgetFallsBackWithoutDroppingLinks() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 42, count: 12).write(to: root.appendingPathComponent("large.txt"))
        let result = try MarkdownFileImport.prepare(source: "[keep](large.txt)", sourceURL: root.appendingPathComponent("test.md"), authorizedRoot: root, staging: root.appendingPathComponent("stage"), remainingBytes: 1)
        #expect(result.content.plainText.contains("large.txt"))
        #expect(result.resourceBytes == 0)
        #expect(!result.warnings.isEmpty)
    }
    @Test func importsAreDurableIdempotentAndRespectSuspension() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let library = NoteLibrary(directory: root.appendingPathComponent("library"), localDirectory: root.appendingPathComponent("local"), createsInitialNote: false)
        #expect(library.entries.isEmpty)
        let reopened = NoteLibrary(directory: library.directory, localDirectory: root.appendingPathComponent("local"))
        #expect(reopened.entries.isEmpty)
        var document = NoteDocument(); document.text = "Imported 中文"; document.isShelved = true
        let first = try library.importDocument(document)
        first.store.edit("User edit"); #expect(first.store.flush())
        let retried = try library.importDocument(document)
        #expect(retried.store === first.store)
        #expect(retried.store.document.text == "User edit")
        #expect(library.entries.count == 1)
        library.setSuspended(true)
        #expect(throws: (any Error).self) { try library.importDocument(NoteDocument()) }
        library.setSuspended(false)
        let reloaded = NoteLibrary(directory: library.directory, localDirectory: root.appendingPathComponent("local"))
        #expect(reloaded.entries.first?.store.document.text == "User edit")
        #expect(reloaded.entries.first?.store.document.isShelved == true)
    }
    @Test func usageProtectsHistoricalAssetsAfterPermanentDeletionWithoutWriting() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), local = root.appendingPathComponent("local")
        let library = NoteLibrary(directory: source, localDirectory: local, createsInitialNote: false)
        let asset = NoteAttachment(name: "keep.txt", byteCount: 11)
        let assetURL = asset.url(in: source.appendingPathComponent("assets/files"))
        try FileManager.default.createDirectory(at: assetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("hello world".utf8).write(to: assetURL)
        var note = NoteDocument(); note.content = NoteContent(blocks: [NoteBlock(kind: .file, attachment: asset)])
        _ = try library.importDocument(note)
        let copied = try LibraryRelocation.copy(source: source, destination: root.appendingPathComponent("managed"), journalURL: local.appendingPathComponent("journal.json"))
        let managed = NoteLibrary(directory: copied.root, manifest: copied.manifest, snapshot: copied.snapshot, localDirectory: local)
        let entry = try #require(managed.entries.first)
        entry.store.edit("No current attachment"); #expect(entry.store.flush())
        #expect(managed.deleteNote(entry.id)); try managed.permanentlyDeleteNote(entry.id)
        let before = try LibraryRelocation.inventory(copied.root)
        let report = try LibraryUsage.scan(root: copied.root)
        let after = try LibraryRelocation.inventory(copied.root)
        #expect(before == after)
        #expect(!report.incomplete)
        let item = try #require(report.largestResources.first)
        #expect(item.bytes == 11)
        #expect(item.references.contains { $0.noteID == note.id && $0.historical })
        #expect(report.bytes(.attachments) == 11)
        #expect(report.bytes(.history) > 0)
    }
    @Test func readOnlyUsageDoesNotReconcileConcurrentHeads() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var note = NoteDocument(); note.text = "base"
        try LibraryRelocation.initialize(root, manifest: LibraryManifest(), notes: [note])
        let base = try LibraryDisk.snapshot(root, reconcile: false)
        let parent = try #require(base.notes[note.id]?.revision)
        note.text = "left"; _ = try LibraryDisk.save(LibraryDisk.encode(LibraryDisk.shared(note)), id: note.id, parent: parent, root: root, kind: "notes")
        note.text = "right"; _ = try LibraryDisk.save(LibraryDisk.encode(LibraryDisk.shared(note)), id: note.id, parent: parent, root: root, kind: "notes")
        let before = try LibraryRelocation.inventory(root)
        let report = try LibraryUsage.scan(root: root)
        #expect(!report.incomplete)
        #expect(report.items.filter { $0.category == .current }.count == 2)
        #expect(try before == LibraryRelocation.inventory(root))
    }
    @Test func unavailableOrUnknownHistoryIsNotConsideredComplete() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("revisions/notes/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: folder.appendingPathComponent(UUID().uuidString + ".json"))
        try Data().write(to: folder.appendingPathComponent(".missing.json.icloud"))
        #expect(try LibraryUsage.scan(root: root).incomplete)
    }
    @Test func loginSettingsUseSystemStateAndRetainFailures() async {
        var systemStatus: SMAppService.Status = .notRegistered
        var registrations = 0
        let model = LoginItemSettings(readStatus: { systemStatus }, register: { registrations += 1; systemStatus = .enabled }, unregister: { throw CocoaError(.fileWriteNoPermission) }, installed: { true })
        await model.setEnabled(true)
        #expect(model.enabled); #expect(registrations == 1)
        await model.setEnabled(false)
        #expect(model.enabled); #expect(model.error != nil); #expect(!model.requestedEnabled)
        systemStatus = .requiresApproval; model.refresh()
        #expect(!model.enabled); #expect(registrations == 1)
        let uninstalled = LoginItemSettings(readStatus: { .notRegistered }, register: { registrations += 1 }, installed: { false })
        await uninstalled.setEnabled(true)
        #expect(!uninstalled.enabled); #expect(uninstalled.error != nil); #expect(registrations == 1)
    }
}
