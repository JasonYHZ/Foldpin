import Foundation
import Testing
@testable import FoldpinCore

@Test func roundTripPreservesUnicodeIdentityAndShelvedLayout() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = NoteFile(url: directory.appendingPathComponent("note.json"))
    var document = NoteDocument()
    document.text = "中文输入\n  let message = \"你好 🌿\"\n\n最后一行"
    document.isPinned = true
    document.isShelved = true
    document.frame = NoteFrame(CGRect(x: -1220, y: 200, width: 360, height: 340))
    try file.save(document)
    #expect(try file.load() == document)
    document.isShelved = false
    try file.save(document)
    #expect(try file.load().id == document.id)
    #expect(try file.load().text == document.text)
    #expect(try file.load().frame == document.frame)
}

@Test func missingFileStartsEmptyWithoutWriting() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("note.json")
    #expect(try NoteFile(url: url).load().text.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func corruptInputIsNotOverwrittenOnLoad() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let original = Data("unfinished { 中文".utf8)
    try original.write(to: url)
    #expect(throws: (any Error).self) { try NoteFile(url: url).load() }
    #expect(try Data(contentsOf: url) == original)
}

@Test func unknownSchemaIsRejectedWithoutChangingOriginal() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    var newer = NoteDocument(); newer.version = 500
    let original = try JSONEncoder().encode(newer)
    try original.write(to: url)
    #expect(throws: NoteFileError.self) { try NoteFile(url: url).load() }
    #expect(try Data(contentsOf: url) == original)
}

@Test func failedSaveThrowsAndKeepsExistingBytes() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let file = NoteFile(url: url)
    var document = NoteDocument(); document.text = "保留这一版"
    try file.save(document)
    let original = try Data(contentsOf: url)
    document.frame = NoteFrame(CGRect(x: 0, y: 0, width: 360, height: 340))
    document.frame?.width = -1
    #expect(throws: NoteFileError.self) { try file.save(document) }
    #expect(try Data(contentsOf: url) == original)
    // A file used as the parent directory must surface an I/O error, not success.
    #expect(throws: (any Error).self) { try NoteFile(url: url.appendingPathComponent("note.json")).save(NoteDocument()) }
}

@Test func disconnectedDisplayMovesWholeWindowIntoReach() {
    let main = CGRect(x: 0, y: 25, width: 1440, height: 850)
    let old = NoteFrame(CGRect(x: -1700, y: 400, width: 360, height: 340))
    #expect(main.contains(old.fitted(to: [main], fallback: main)))
    let huge = NoteFrame(CGRect(x: 1200, y: 760, width: 2200, height: 1800))
    #expect(main.contains(huge.fitted(to: [main], fallback: main)))
}

@Test func attachedNegativeCoordinateDisplayKeepsOriginalPosition() {
    let main = CGRect(x: 0, y: 25, width: 1440, height: 850)
    let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    let old = NoteFrame(CGRect(x: -800, y: 320, width: 360, height: 340))
    #expect(old.fitted(to: [main, left], fallback: main) == old.rect)
}

@Test func legacyNoteWithoutCollapseFieldLoadsUnchanged() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let file = NoteFile(url: url)
    var document = NoteDocument()
    document.text = "已有纸片\n不因升级丢失"
    document.isPinned = true
    document.frame = NoteFrame(CGRect(x: 12, y: 90, width: 360, height: 340))
    try file.save(document)
    let saved = try file.load()
    var legacy = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    legacy.removeValue(forKey: "isCollapsed")
    let original = try JSONSerialization.data(withJSONObject: legacy)
    try original.write(to: url)
    #expect(try file.load() == saved)
    #expect(try Data(contentsOf: url) == original)
}

@Test func repeatedCollapseKeepsTopEdgeAndDisconnectedStripStaysOneLine() {
    let expanded = CGRect(x: -800, y: 320, width: 360, height: 480)
    var frame = expanded
    for _ in 0..<20 {
        let strip = NoteLayout.visibleFrame(expanded: frame, collapsed: true)
        #expect(strip.maxY == expanded.maxY)
        #expect(strip.height == 34)
        frame = NoteLayout.expandedFrame(window: strip, collapsed: true, rememberedHeight: frame.height)
    }
    #expect(frame == expanded)
    let main = CGRect(x: 0, y: 25, width: 1440, height: 850)
    let strip = NoteLayout.visibleFrame(expanded: expanded, collapsed: true)
    let fitted = NoteFrame(strip).fitted(to: [main], fallback: main,
                                        minimumSize: CGSize(width: 280, height: 34))
    #expect(main.contains(fitted))
    #expect(fitted.height == 34)
    let restored = NoteLayout.expandedFrame(window: fitted, collapsed: true, rememberedHeight: 480)
    #expect(restored.height == 480)
    #expect(restored.maxY == fitted.maxY)
}
