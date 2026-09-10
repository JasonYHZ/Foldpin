import AppKit
import Testing
@testable import FoldpinCore

@Suite(.serialized)
struct NoteSearchTests {
    @Test func noteSearchUnicodeFieldsAndCase() throws {
        let image = NoteImage(id: UUID(), name: "hidden cat", pixelWidth: 100, pixelHeight: 100, caption: "cat 图片")
        let document = NoteContent(blocks: [
            NoteBlock(text: "猫👩🏽‍💻 CAT cat"), NoteBlock(kind: .code, text: "cat()"),
            NoteBlock(kind: .table, table: NoteTable(rows: [["cat", "x"], ["cat", "y"]])),
            NoteBlock(kind: .image, image: image)
        ])
        let result = NoteSearch.find(in: document, query: "cat", caseSensitive: false)
        #expect(result.hits.count == 6)
        #expect(NoteSearch.find(in: document, query: "cat", caseSensitive: true).hits.count == 5)
        let emoji = NoteSearch.find(in: document, query: "👩🏽‍💻", caseSensitive: false)
        #expect(emoji.hits.first?.range == NSRange(location: 1, length: 7))
        let changed = try #require(NoteSearch.replacing(result.hits, in: document, with: "狗🐕"))
        #expect(changed.blocks[0].text == "猫👩🏽‍💻 狗🐕 狗🐕")
        #expect(changed.blocks[1].kind == .code && changed.blocks[1].text == "狗🐕()")
        #expect(changed.blocks[2].table?.rows[1][0] == "狗🐕")
        #expect(changed.blocks[3].image?.caption == "狗🐕 图片")
        #expect(changed.blocks[3].image?.id == image.id && changed.blocks[3].image?.name == "hidden cat")
        #expect(changed.blocks.map(\.id) == document.blocks.map(\.id))
        #expect(NoteSearch.find(in: document, query: "", caseSensitive: false).hits.isEmpty)
        #expect(NoteSearch.find(in: document, query: "cat\ncat", caseSensitive: false).hits.isEmpty)
    }

    @Test func noteSearchReplacementPreservesMarksAndDoesNotRecursivelyReplace() throws {
        let document = NoteContent(blocks: [NoteBlock(text: "a cat z cat", marks: [
            NoteTextMark(location: 2, length: 3, bold: true, link: "https://example.com"),
            NoteTextMark(location: 6, length: 5, italic: true)
        ])])
        let hits = NoteSearch.find(in: document, query: "cat", caseSensitive: false).hits
        let replaced = try #require(NoteSearch.replacing(hits, in: document, with: "catcat"))
        #expect(replaced.blocks[0].text == "a catcat z catcat")
        #expect(replaced.blocks[0].marks.contains { $0.location == 2 && $0.length == 6 && $0.bold && $0.link != nil })
        #expect(replaced.blocks[0].marks.contains { $0.location == 9 && $0.italic })
        let removed = try #require(NoteSearch.replacing(hits, in: document, with: ""))
        #expect(removed.blocks[0].text == "a  z ")
        #expect((try? removed.validate()) != nil)
    }

    @Test func noteSearchLargeInputCancellationAndResultBound() {
        let document = NoteContent(blocks: [NoteBlock(text: String(repeating: "token ", count: 100_000))])
        let clock = ContinuousClock(), start = clock.now
        let result = NoteSearch.find(in: document, query: "token", caseSensitive: false)
        print("Note search 600k UTF-16:", start.duration(to: clock.now), "matches:", result.hits.count)
        #expect(result.hits.count == NoteSearch.limit && result.truncated)
        var calls = 0
        let cancelled = NoteSearch.find(in: document, query: "token", caseSensitive: false, cancelled: { calls += 1; return calls > 10 })
        #expect(cancelled.hits.isEmpty && calls == 11)
    }

    @Test @MainActor func noteSearchNativeUndoStaleResultsAndLayout() async throws {
        _ = NSApplication.shared
        let editor = PaperTextView(usingTextLayoutManager: true)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        scroll.drawsBackground = true; scroll.backgroundColor = .white
        editor.frame = scroll.bounds; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 20, height: 8)
        scroll.documentView = editor
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.appearance = NSAppearance(named: .aqua)
        let delegate = FindUndoDelegate(); delegate.history.groupsByEvent = false
        editor.delegate = delegate; editor.allowsUndo = true
        let original = NoteContent(blocks: [
            NoteBlock(text: "cat one cat two 猫"),
            NoteBlock(kind: .code, text: "let cat = 1"),
            NoteBlock(kind: .table, table: NoteTable(rows: [["table cat", "other"], ["猫", "test"]])),
            NoteBlock(kind: .image, image: NoteImage(id: UUID(), name: "sample", pixelWidth: 160, pixelHeight: 70, caption: "image cat"))
        ])
        editor.configure(content: original)
        defer { editor.closeNoteFind(); window.close() }
        editor.setSelectedRange(NSRange(location: 4, length: 3))
        editor.showNoteFind(replacing: true)
        let bar = try #require(editor.findBar)
        bar.query.stringValue = "cat"; editor.scheduleNoteSearch()
        try await wait { editor.findResult.hits.count == 5 }
        #expect(editor.content == original && editor.selectedRange() == NSRange(location: 4, length: 3) && !delegate.history.canUndo)
        bar.replacement.stringValue = "dog"
        delegate.history.beginUndoGrouping(); editor.replaceNoteSearch(all: true)
        try await wait { editor.content.blocks[0].text == "dog one dog two 猫" }
        delegate.history.endUndoGrouping()
        #expect(editor.content.blocks[2].table?.rows[0][0] == "table dog")
        #expect(editor.content.blocks[3].image?.caption == "image dog")
        let undoEvent = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        #expect(editor.handleFindHistory(undoEvent))
        #expect(editor.content == original)
        try await wait { editor.findResult.hits.count == 5 }
        editor.isEditable = false; editor.replaceNoteSearch(all: true)
        #expect(editor.content == original)
        editor.isEditable = true
        bar.query.stringValue = "dog"; editor.scheduleNoteSearch()
        bar.query.stringValue = "cat"; editor.scheduleNoteSearch()
        try await wait { editor.findResult.hits.count == 5 }
        try await Task.sleep(for: .milliseconds(100))
        scroll.layoutSubtreeIfNeeded(); scroll.display()
        #expect(bar.frame.height == 92 && bar.query.frame.width > 80)
        let bitmap = try #require(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
        scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/foldpin-find-preview.png"))
        bar.toggleReplacement(); scroll.layoutSubtreeIfNeeded()
        #expect(bar.frame.height == 54 && bar.replacement.isHidden)
        bar.toggleReplacement(); scroll.layoutSubtreeIfNeeded()
        #expect(bar.frame.height == 92 && !bar.replacement.isHidden && editor.content == original)
        // Match the reference's empty, expanded, dark state at 2x density.
        bar.query.stringValue = ""; editor.scheduleNoteSearch()
        bar.replacement.stringValue = ""
        scroll.setFrameSize(NSSize(width: 380, height: 600))
        window.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(100))
        scroll.layoutSubtreeIfNeeded(); bar.layoutSubtreeIfNeeded(); bar.display()
        let dark = try #require(bar.bitmapImageRepForCachingDisplay(in: bar.bounds))
        bar.cacheDisplay(in: bar.bounds, to: dark)
        try #require(dark.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/foldpin-find-dark.png"))
        editor.closeNoteFind()
        #expect(editor.findResult.hits.isEmpty && !scroll.isFindBarVisible && editor.content == original)
    }
    @Test @MainActor func editorGlassSurfaceKeepsControlsDuringAccessibilityFallback() {
        _ = NSApplication.shared
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        field.stringValue = "保留查询 draft"; content.addSubview(field)
        let surface = EditorGlassSurface(content: content, cornerRadius: 17)
        surface.requiresSolidBackground = { false }; surface.refreshMaterial()
        surface.layoutSubtreeIfNeeded()
        #expect(surface.usesGlass && surface.content === content && field.isDescendant(of: surface))
        surface.requiresSolidBackground = { true }; surface.refreshMaterial(); surface.layoutSubtreeIfNeeded()
        #expect(!surface.usesGlass && content.superview === surface && field.stringValue == "保留查询 draft")
        #expect(surface.hitTest(NSPoint(x: 25, y: 25)) === field)
        surface.requiresSolidBackground = { false }; surface.refreshMaterial(); surface.layoutSubtreeIfNeeded()
        #expect(surface.usesGlass && field.isDescendant(of: surface) && field.stringValue == "保留查询 draft")
    }

    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(predicate())
    }
}

@MainActor private final class FindUndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}
