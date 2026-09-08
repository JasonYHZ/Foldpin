import Foundation
import Testing
@testable import FoldpinCore

@Test @MainActor func autosaveWritesLatestEditWithoutExplicitFlush() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = NoteFile(url: directory.appendingPathComponent("note.json"))
    let store = NoteStore(file: file)
    store.edit("第一段")
    store.edit("最后编辑的中文\n  缩进仍然保留")
    try await Task.sleep(for: .seconds(1))
    #expect(!store.isDirty)
    #expect(try file.load().text == "最后编辑的中文\n  缩进仍然保留")
}

@Test @MainActor func storeFailureKeepsUnsavedTextAndCanRetry() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("file blocks directory creation".utf8).write(to: directory)
    let store = NoteStore(file: NoteFile(url: directory.appendingPathComponent("note.json")))
    store.edit("还没有保存的中文内容")
    #expect(!store.flush())
    #expect(store.isDirty)
    #expect(store.saveError != nil)
    #expect(store.document.text == "还没有保存的中文内容")
    try FileManager.default.removeItem(at: directory)
    #expect(store.flush())
    #expect(!store.isDirty)
    #expect(store.saveError == nil)
    #expect(try store.file.load().text == "还没有保存的中文内容")
}

@Test @MainActor func blockedLoadCannotAutosaveEmptyNoteOverOriginal() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let original = Data("broken JSON that must survive".utf8)
    try original.write(to: url)
    let store = NoteStore(file: NoteFile(url: url))
    #expect(store.loadError != nil)
    store.edit("不应覆盖原文件")
    store.setShelved(true)
    store.setCollapsed(true)
    store.recordWindowFrame(CGRect(x: 40, y: 200, width: 360, height: 34), collapsed: true)
    #expect(!store.isCollapsed)
    #expect(!store.flush())
    #expect(try Data(contentsOf: url) == original)
}

@Test @MainActor func collapsedStripMoveAndRestartPreserveExpandedSizeAndContent() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = NoteFile(url: directory.appendingPathComponent("note.json"))
    let store = NoteStore(file: file)
    store.edit("折叠后仍在桌面\n  中文、缩进与 🌿 都保留")
    store.setFrame(CGRect(x: -800, y: 320, width: 360, height: 480))
    let original = store.document
    store.setCollapsed(true)
    // Move and horizontally resize the visible strip on a second display.
    store.recordWindowFrame(CGRect(x: -720, y: 666, width: 420, height: 34), collapsed: true)
    #expect(store.flush())
    let restarted = NoteStore(file: file)
    #expect(restarted.isCollapsed)
    #expect(restarted.document.id == original.id)
    #expect(restarted.document.text == original.text)
    #expect(restarted.document.frame?.rect == CGRect(x: -720, y: 220, width: 420, height: 480))
    restarted.setCollapsed(false)
    #expect(restarted.flush())
    #expect(try file.load().frame?.rect.maxY == 700)
    #expect(try file.load().frame?.height == 480)
}

@Test @MainActor func shelvingCollapsedNoteRestoresSameStripAfterRestart() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = NoteFile(url: directory.appendingPathComponent("note.json"))
    let store = NoteStore(file: file)
    store.edit("关闭只收纳，不删除")
    store.setFrame(CGRect(x: 500, y: 200, width: 360, height: 340))
    store.setPinned(true)
    store.setCollapsed(true)
    store.setShelved(true)
    #expect(store.flush())
    let restarted = NoteStore(file: file)
    #expect(restarted.document == store.document)
    restarted.setShelved(false)
    #expect(restarted.isCollapsed)
    #expect(restarted.document.isPinned)
    #expect(restarted.document.text == "关闭只收纳，不删除")
    #expect(restarted.flush())
    #expect(try file.load().frame?.height == 340)
}

@Test @MainActor func shelveAndRestartKeepIdentityTextAndPin() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = NoteFile(url: directory.appendingPathComponent("note.json"))
    let first = NoteStore(file: file)
    first.edit("一张真实的纸片\n  继续工作")
    first.setPinned(true)
    first.setFrame(CGRect(x: 500, y: 200, width: 360, height: 340))
    first.setShelved(true)
    #expect(first.flush())
    let restarted = NoteStore(file: file)
    #expect(restarted.document == first.document)
    #expect(restarted.document.isShelved)
    restarted.setShelved(false)
    #expect(restarted.flush())
    #expect(restarted.document.id == first.document.id)
    #expect(restarted.document.text == first.document.text)
    #expect(restarted.document.isPinned)
}
