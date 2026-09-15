import AppKit
import SwiftUI
import Testing
import ServiceManagement
@testable import FoldpinCore

@MainActor private func readinessFixture() throws -> URL {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLDPIN_CHECK_DATA"]!).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
@Test @MainActor func readinessNativeImportRetryAndCancellation() async throws {
    let root = try readinessFixture()
    let storage = LibraryLocationController(privateDirectory: root.appendingPathComponent("local"), defaultDirectory: root.appendingPathComponent("library"))
    let one = root.appendingPathComponent("one.md"), two = root.appendingPathComponent("two.md")
    let asset = root.appendingPathComponent("document.txt")
    try Data("Original attachment".utf8).write(to: asset)
    try Data("# First\n\nKeep this\n\n[Document](document.txt)".utf8).write(to: one)
    try Data([0xff, 0xaa]).write(to: two)
    let importer = MarkdownFileImportController()
    importer.configure(sources: [one, two], storage: storage, resourceRoot: root)
    importer.run()
    #expect(LibraryFileActivity.imports == 1)
    let original = storage.library
    storage.open(root.appendingPathComponent("must-not-open"))
    #expect(storage.library === original)
    #expect(!storage.isBusy)
    for _ in 0..<500 where importer.busy { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!importer.busy)
    #expect(importer.rows.filter(\.succeeded).count == 1)
    #expect(LibraryFileActivity.imports == 0)
    let entry = try #require(storage.library.entries.first)
    let attachment = try #require(entry.store.document.content.blocks.compactMap(\.attachment).first)
    try FileManager.default.removeItem(at: asset)
    #expect(try Data(contentsOf: entry.store.file.attachmentURL(attachment)) == Data("Original attachment".utf8))
    entry.store.edit("Edited after importing"); #expect(entry.store.flush())
    try Data("Second".utf8).write(to: two)
    importer.run()
    for _ in 0..<500 where importer.busy { try await Task.sleep(for: .milliseconds(10)) }
    #expect(importer.rows.filter(\.succeeded).count == 2)
    #expect(storage.library.entries.count == 2)
    #expect(entry.store.document.text == "Edited after importing")
    #expect(storage.library.entries.allSatisfy { $0.store.document.isShelved })
    importer.configure(sources: [one], storage: storage, resourceRoot: nil)
    importer.run(); importer.cancel()
    for _ in 0..<500 where importer.busy { try await Task.sleep(for: .milliseconds(10)) }
    #expect(storage.library.entries.count == 2)
    #expect(LibraryFileActivity.imports == 0)
}
@Test @MainActor func readinessNativeLayoutAndMenu() async throws {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.appearance = NSAppearance(named: .aqua)
    let root = try readinessFixture()
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLDPIN_CHECK_OUTPUT"]!)
    let library = NoteLibrary(directory: root.appendingPathComponent("library"), localDirectory: root.appendingPathComponent("local"), createsInitialNote: false)
    var note = NoteDocument(); note.text = "Find the imported note"; note.isShelved = true
    let entry = try library.importDocument(note)
    let owner = ShelfPreviewWindow(library: library, resolve: { _ in nil }, onNew: {}, onRetry: {}, onRestore: { _ in })
    owner.window.contentView?.layoutSubtreeIfNeeded()
    let item = try #require(owner.window.toolbar?.items.first { $0.itemIdentifier.rawValue == "shelf.new" } as? NSMenuToolbarItem)
    #expect(item.menu.items.count == 2)
    owner.revealNote(entry.id)
    #expect(owner.selectedEntry?.id == entry.id)
    #expect(owner.query.isEmpty && owner.typeFilter == "All Types")
    let suite = "Foldpin.Guide.Native." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let guide = try GettingStartedNote(defaults: defaults).open(in: library, bundle: LanguageSettings.shared.bundle, shortcuts: ShortcutSettings(defaults: defaults))
    let paper = PaperWindowController(entry: guide, initialFrame: NSRect(x: 0, y: 0, width: 520, height: 680))
    defer { paper.dispose() }
    let content = try #require(paper.paper.contentView)
    for _ in 0..<8 { try await Task.sleep(for: .milliseconds(25)); content.layoutSubtreeIfNeeded() }
    #expect(guide.store.document.text.contains("使用说明"))
    #expect(!paper.paper.isVisible)
    if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("first-use-note.png"))
    }
    let preview = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
    preview.isReleasedWhenClosed = false
    let login = LoginItemSettings(readStatus: { .requiresApproval }, register: {}, unregister: {}, installed: { true })
    let settings = NSHostingView(rootView: GeneralSettingsView(login: login))
    preview.setContentSize(NSSize(width: 560, height: 460)); preview.contentView = settings
    for _ in 0..<8 { try await Task.sleep(for: .milliseconds(25)); settings.layoutSubtreeIfNeeded() }
    if let bitmap = settings.bitmapImageRepForCachingDisplay(in: settings.bounds) {
        settings.cacheDisplay(in: settings.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("general-settings.png"))
    }
    preview.contentView = nil; preview.close(); owner.window.close()
}
