import Foundation
import Testing
@testable import FoldpinCore

@Test func noteIconAcceptsWholeEmojiAndRejectsTextWithoutTruncating() {
    for emoji in NoteIcon.suggestions + ["👩🏽‍💻", "👨‍👩‍👧‍👦", "🏳️‍🌈", "🇨🇳", "🇺🇸", "1️⃣", "#️⃣", "❤️‍🔥"] {
        #expect(NoteIcon.normalized(emoji) == emoji)
        #expect(NoteIcon.normalized(" \n" + emoji + "\n ") == emoji)
    }
    for invalid in ["", " ", "A", "工作", "1", "#", "*", "🌿📝", "🌿 title", "🇨", "🏽", "\u{200D}", "a\u{0301}", "🌿\u{0301}", "\u{202E}🌿"] {
        #expect(NoteIcon.normalized(invalid) == nil)
    }
    #expect(NoteIcon.normalized(String(repeating: "🌿", count: 200)) == nil)
}

@Test func noteIconLoadsOldNotesAndInvalidMetadataWithoutChangingSource() throws {
    var note = NoteDocument()
    note.content = NoteContent(blocks: [NoteBlock(kind: .heading, text: "项目标题"), NoteBlock(text: "保留内容 🌿")])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = NoteFile(url: root.appendingPathComponent("note.json"))
    for version in [1, 2] {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(note)) as? [String: Any])
        json["version"] = version
        if version == 1 { json["text"] = note.text; json.removeValue(forKey: "content") }
        for value: String? in [nil, "plain text", "🌿📝", "", "👩🏽‍💻"] {
            if let value { json["icon"] = value } else { json.removeValue(forKey: "icon") }
            let bytes = try JSONSerialization.data(withJSONObject: json)
            try bytes.write(to: file.url)
            let loaded = try file.load()
            #expect(loaded.id == note.id && loaded.text == note.text)
            #expect(loaded.icon == value.flatMap(NoteIcon.normalized))
            if version == 2 { #expect(loaded.content == note.content) }
            #expect(try Data(contentsOf: file.url) == bytes)
        }
    }
}

@Test @MainActor func noteIconPersistsPerNoteCanChangeAndRemoveWithoutEditingBody() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = NoteStore(file: NoteFile(url: root.appendingPathComponent("a.json")))
    let b = NoteStore(file: NoteFile(url: root.appendingPathComponent("b.json")))
    a.edit(NoteContent(blocks: [NoteBlock(kind: .heading, text: "独立图标"), NoteBlock(kind: .code, text: "let n = 1", language: .swift)]))
    a.setColor(.green)
    a.setFrame(CGRect(x: -650, y: 240, width: 360, height: 480))
    a.setPinned(true); a.setCollapsed(true); a.setShelved(true)
    b.edit("另一张纸片")
    #expect(a.flush() && b.flush())
    var expected = a.document
    let untouched = b.document
    for icon: String? in ["💡", "👩🏽‍💻", "🇨🇳", nil] {
        #expect(a.setIcon(icon))
        expected.icon = icon
        #expect(a.document == expected && b.document == untouched)
        #expect(a.document.summary() == "独立图标")
        #expect(a.flush())
        #expect(NoteStore(file: a.file).document == expected)
        #expect(a.setIcon(icon) && !a.isDirty)
    }
    #expect(a.setIcon("📌") && b.setIcon("🌿"))
    #expect(a.flush() && b.flush())
    #expect(NoteStore(file: a.file).document.icon == "📌")
    #expect(NoteStore(file: b.file).document.icon == "🌿")
    let prior = a.document
    #expect(!a.setIcon("two words") && !a.setIcon("🌿📌"))
    #expect(a.document == prior && !a.isDirty)
}

@Test @MainActor func noteIconSaveFailureKeepsDraftAndCorruptFileRemainsProtected() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("blocked parent".utf8).write(to: root)
    let store = NoteStore(file: NoteFile(url: root.appendingPathComponent("note.json")))
    store.edit("尚未保存的正文")
    #expect(store.setIcon("📝"))
    #expect(!store.flush() && store.isDirty && store.saveError != nil)
    #expect(store.document.icon == "📝" && store.document.text == "尚未保存的正文")
    try FileManager.default.removeItem(at: root)
    #expect(store.flush())
    #expect(try store.file.load() == store.document)
    let file = root.appendingPathComponent("broken.json")
    let bytes = Data("corrupt original".utf8)
    try bytes.write(to: file)
    let locked = NoteStore(file: NoteFile(url: file))
    #expect(locked.loadError != nil && !locked.setIcon("💡") && !locked.setIcon(nil))
    #expect(!locked.flush() && !locked.isDirty && locked.document.icon == nil)
    #expect(try Data(contentsOf: file) == bytes)
}
