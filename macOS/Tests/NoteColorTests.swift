import AppKit
import Testing
@testable import FoldpinCore

@Test func noteColorLoadsLegacyAndUnknownPresetsWithoutRewritingContent() throws {
    var note = NoteDocument()
    note.content = NoteContent(blocks: [NoteBlock(kind: .heading, text: "保留标题"), NoteBlock(text: "中文 🌿")])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = NoteFile(url: root.appendingPathComponent("note.json"))
    for version in [1, 2] {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(note)) as? [String: Any])
        json["version"] = version
        if version == 1 { json["text"] = note.text; json.removeValue(forKey: "content") }
        for preset: String? in [nil, "future-color"] {
            if let preset { json["color"] = preset } else { json.removeValue(forKey: "color") }
            let bytes = try JSONSerialization.data(withJSONObject: json)
            try bytes.write(to: file.url)
            let loaded = try file.load()
            #expect(loaded.color == .original && loaded.id == note.id && loaded.text == note.text)
            if version == 2 { #expect(loaded.content == note.content) }
            #expect(try Data(contentsOf: file.url) == bytes)
        }
    }
}

@Test @MainActor func noteColorPersistsPerNoteAndPreservesContentAndLayout() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = NoteStore(file: NoteFile(url: root.appendingPathComponent("a.json")))
    let b = NoteStore(file: NoteFile(url: root.appendingPathComponent("b.json")))
    a.edit(NoteContent(blocks: [NoteBlock(kind: .heading, text: "项目"), NoteBlock(kind: .code, text: "let n = 1", language: .swift)]))
    a.setPinned(true)
    a.setFrame(CGRect(x: -500, y: 240, width: 360, height: 480))
    a.setCollapsed(true)
    a.setShelved(true)
    b.edit("另一张独立纸片")
    #expect(a.flush() && b.flush())
    var expected = a.document
    let untouched = b.document
    for color in NoteColor.allCases {
        a.setColor(color)
        expected.color = color
        #expect(a.document == expected && b.document == untouched)
        #expect(a.flush())
        #expect(NoteStore(file: a.file).document == expected)
    }
    a.setColor(.blue)
    b.setColor(.pink)
    #expect(a.flush() && b.flush())
    #expect(NoteStore(file: a.file).document.color == .blue)
    #expect(NoteStore(file: b.file).document.color == .pink)
}

@Test @MainActor func noteColorSaveFailureCanRetryAndUnreadableFileStaysProtected() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("blocked parent".utf8).write(to: root)
    let store = NoteStore(file: NoteFile(url: root.appendingPathComponent("note.json")))
    store.edit("尚未保存")
    store.setColor(.green)
    #expect(!store.flush() && store.isDirty && store.saveError != nil)
    #expect(store.document.color == .green && store.document.text == "尚未保存")
    try FileManager.default.removeItem(at: root)
    #expect(store.flush())
    #expect(try store.file.load() == store.document)
    let broken = root.appendingPathComponent("broken.json")
    let bytes = Data("broken original".utf8)
    try bytes.write(to: broken)
    let locked = NoteStore(file: NoteFile(url: broken))
    let initial = locked.document
    locked.setColor(.purple)
    #expect(locked.document == initial && !locked.flush())
    #expect(try Data(contentsOf: broken) == bytes)
}

@Test @MainActor func noteColorPalettesKeepReadableInkInBothAppearances() throws {
    func resolved(_ color: NSColor) -> [Double] {
        let c = color.usingColorSpace(.sRGB)!
        return [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent)]
    }
    func luminance(_ rgb: [Double]) -> Double {
        zip([0.2126, 0.7152, 0.0722], rgb).reduce(0) { value, pair in
            value + pair.0 * (pair.1 <= 0.04045 ? pair.1 / 12.92 : pow((pair.1 + 0.055) / 1.055, 2.4))
        }
    }
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        let appearance = try #require(NSAppearance(named: name))
        appearance.performAsCurrentDrawingAppearance {
            for color in NoteColor.allCases {
                let background = resolved(NotePalette.paperBackground(for: color))
                for ink in [NotePalette.paperText, NotePalette.paperSecondaryText, NotePalette.paperPlaceholderText,
                            NotePalette.paperLink, NotePalette.paperError] {
                    let foreground = resolved(ink)
                    let composite = (0..<3).map { foreground[$0] * foreground[3] + background[$0] * (1 - foreground[3]) }
                    let a = luminance(background), b = luminance(composite)
                    #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5)
                }
            }
        }
    }
}

@Test @MainActor func noteColorChangesKeepActiveTableCellAndMarkedText() throws {
    let block = NoteBlock(kind: .table)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.frame = NSRect(x: 0, y: 0, width: 480, height: 800)
    editor.textContainerInset = NSSize(width: 32, height: 16)
    editor.textContainer?.lineFragmentPadding = 0
    editor.textContainer?.size = NSSize(width: 416, height: 100_000)
    editor.textContainer?.widthTracksTextView = true
    editor.isRichText = true
    editor.noteColor = NotePalette.paperText
    scroll.documentView = editor
    defer { scroll.documentView = nil }
    editor.configure(content: NoteContent(blocks: [block, NoteBlock()]))
    editor.beginTableCellEditing(blockID: block.id, row: 0, column: 0)
    let cell = try #require(editor.tableCellEditor)
    cell.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: cell.selectedRange())
    let content = editor.content, selection = cell.selectedRange(), marked = cell.markedRange()
    var publications = 0
    editor.onContentChange = { _ in publications += 1 }
    for color in NoteColor.allCases {
        editor.updatePaperBackground(NotePalette.paperBackground(for: color))
        #expect(editor.tableCellEditor === cell && cell.hasMarkedText())
        #expect(cell.selectedRange() == selection && cell.markedRange() == marked)
        #expect(cell.backgroundColor == NotePalette.paperBackground(for: color))
        #expect(editor.content == content && publications == 0)
    }
}
