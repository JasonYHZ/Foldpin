import AppKit
import SwiftUI
import Testing
@testable import FoldpinCore

@Test @MainActor func editorHandoff() async throws {
    UserDefaults.standard.setVolatileDomain(["noteAppearance": "paper"], forName: UserDefaults.argumentDomain)
    NSApplication.shared.setActivationPolicy(.prohibited)
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLDPIN_CHECK_DATA"]!)
    let library = NoteLibrary(directory: directory)
    let entry = try #require(library.entries.first)
    let image = NoteImage(id: UUID(), name: "synthetic.png", pixelWidth: 1, pixelHeight: 1,
        remoteSource: "https://example.invalid/image.png", remoteState: .failed)
    // Structural fixtures only: never load a decoder or start playback/recording.
    let audio = NoteAudio(name: "Synthetic", fileExtension: "wav", duration: 1)
    let video = NoteVideo(name: "Synthetic", fileExtension: "mp4", duration: 1, pixelWidth: 10, pixelHeight: 10)
    try FileManager.default.createDirectory(at: entry.store.file.audioURL(audio).deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("synthetic audio".utf8).write(to: entry.store.file.audioURL(audio))
    try Data("synthetic video".utf8).write(to: entry.store.file.videoURL(video))
    let table = NoteBlock(kind: .table, table: NoteTable(rows: [["中文", "值"], ["测试", "1"]]))
    entry.store.edit(NoteContent(blocks: [NoteBlock(text: "Synthetic"), NoteBlock(kind: .task, text: "Task"),
        NoteBlock(kind: .code, text: "let x = 1"), table,
        NoteBlock(kind: .image, image: image), NoteBlock(kind: .audio, audio: audio), NoteBlock(kind: .video, video: video)]))
    #expect(entry.store.flush())
    _ = try #require(NSScreen.main, "Native check requires WindowServer access.")
    let controller = PaperWindowController(entry: entry)
    defer { controller.dispose() }
    controller.paper.contentView?.layoutSubtreeIfNeeded()
    // Allow the SwiftUI representable to install its desktop slot without ordering a window front.
    try await Task.sleep(for: .milliseconds(200))
    let session = controller.session
    let editor = session.host.editor
    let desktop = try #require(session.desktopSlot)
    let history = try #require(editor.undoManager)
    history.groupsByEvent = false
    let preview = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 450),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
    preview.isReleasedWhenClosed = false
    let slot = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 450))
    preview.contentView = slot
    defer { preview.contentView = nil; preview.close() }
    func type(_ text: String) {
        history.beginUndoGrouping()
        editor.insertText(text, replacementRange: editor.selectedRange())
        history.endUndoGrouping()
    }
    editor.setSelectedRange(NSRange(location: 0, length: 0))
    type("Desktop ")
    let fromDesktop = entry.store.document.content
    let selection = editor.selectedRange()
    #expect(controller.shelvePaper(restoringFocus: false))
    #expect(session.beginPreview(in: slot))
    #expect(session.host.superview === slot && editor.undoManager === history)
    #expect(editor.selectedRange() == selection)
    history.undo()
    #expect(!entry.store.document.content.plainText.contains("Desktop "))
    history.redo()
    #expect(entry.store.document.content == fromDesktop)
    type("Preview ")
    let fromPreview = entry.store.document.content
    #expect(session.endPreview())
    #expect(session.host.superview === desktop && editor.undoManager === history)
    history.undo()
    #expect(entry.store.document.content == fromDesktop)
    history.redo()
    #expect(entry.store.document.content == fromPreview)
    #expect(entry.store.document.content.blocks.map(\.kind) == [.paragraph, .task, .code, .table, .image, .audio, .video])
    #expect(entry.store.document.content.blocks[3].table == table.table)
    #expect(entry.store.document.content.blocks[4].image == image)
    #expect(entry.store.document.content.blocks[5].audio == audio)
    #expect(entry.store.document.content.blocks[6].video == video)
    for _ in 0..<20 {
        let selected = editor.selectedRange()
        #expect(session.beginPreview(in: slot))
        #expect(session.endPreview())
        #expect(session.host.editor === editor && editor.undoManager === history)
        #expect(editor.selectedRange() == selected)
    }
    #expect(session.beginPreview(in: slot))
    history.beginUndoGrouping()
    editor.setMarkedText("中文组合", selectedRange: NSRange(location: 4, length: 0), replacementRange: editor.selectedRange())
    #expect(session.endPreview())
    history.endUndoGrouping()
    #expect(!editor.hasMarkedText())
    #expect(entry.store.document.content.plainText.components(separatedBy: "中文组合").count == 2)
    #expect(session.beginPreview(in: slot))
    type("Unsaved ")
    let unsaved = entry.store.document.content
    // Replace only this synthetic note's destination with a directory to force atomic-write failure.
    let url = entry.store.file.url
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    #expect(!session.endPreview())
    #expect(session.inPreview && session.host.superview === slot)
    #expect(entry.store.saveError != nil && entry.store.document.content == unsaved)
    try FileManager.default.removeItem(at: url)
    #expect(session.endPreview())
    #expect(try entry.store.file.load().content == unsaved)
    #expect(!controller.paper.isVisible && !preview.isVisible)
    // A live desktop document can lend its editor without being shelved.
    entry.store.setShelved(false)
    #expect(entry.store.flush())
    #expect(session.beginPreview(in: slot))
    #expect(!entry.store.document.isShelved && session.host.superview === slot)
    #expect(session.endPreview())
    #expect(session.host.superview === desktop)
    entry.store.setShelved(true)
    #expect(entry.store.flush())
    #expect(session.beginPreview(in: slot))
    editor.beginTableCellEditing(blockID: table.id, row: 0, column: 0)
    let cell = try #require(editor.tableCellEditor)
    history.beginUndoGrouping()
    cell.setMarkedText("表格中文", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: 0, length: (cell.string as NSString).length))
    #expect(session.endPreview())
    history.endUndoGrouping()
    #expect(!cell.hasMarkedText())
    #expect(entry.store.document.content.blocks[3].table?.rows[0][0] == "表格中文")
    #expect(editor.tableCellEditor === cell && cell.undoManager === history)

}
