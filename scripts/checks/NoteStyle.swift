import AppKit
import Testing
@testable import FoldpinCore

@Test @MainActor func noteStyleUpdatesPreserveEditing() async throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let defaults = UserDefaults(suiteName: "Foldpin.NoteStyle.Check")!
    defaults.removePersistentDomain(forName: "Foldpin.NoteStyle.Check")
    let style = NoteStyleSettings.shared
    style.update { $0 = NoteStylePreferences() }
    defer {
        style.update { $0 = NoteStylePreferences() }
        defaults.removePersistentDomain(forName: "Foldpin.NoteStyle.Check")
    }
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.frame = NSRect(x: 0, y: 0, width: 420, height: 480)
    editor.textContainer?.containerSize = NSSize(width: 356, height: CGFloat.greatestFiniteMagnitude)
    editor.isRichText = true
    editor.allowsUndo = true
    let history = UndoManager()
    history.groupsByEvent = false
    editor.sessionUndoManager = history
    let original = NoteContent(blocks: [NoteBlock(text: "中文文字 sample")])
    editor.configure(content: original)
    editor.setSelectedRange(NSRange(location: 2, length: 0))
    history.beginUndoGrouping()
    editor.insertNewline(nil)
    history.endUndoGrouping()
    let content = editor.content
    let selection = editor.selectedRanges
    var contentWrites = 0
    editor.onContentChange = { _ in contentWrites += 1 }
    let table = NoteTable(rows: [[String(repeating: "word ", count: 10), "中文"]])
    let oldLayout = TableBlockLayout(table: table, width: 220)
    let theme = NativeCodeTheme.github
    let oldCode = try #require(theme.attributes(for: .keyword, language: .swift)[.font] as? NSFont)
    #expect(oldCode.pointSize == 13)
    style.update {
        $0.typography.bodyFamily = "Helvetica"
        $0.typography.bodySize = 24
        $0.typography.codeSize = 20
        $0.typography.lineSpacing = 8
        $0.paperOpacity = 0.4
        $0.clearGlass = true
    }
    try await Task.sleep(for: .milliseconds(180))
    #expect(editor.content == content)
    #expect(editor.selectedRanges == selection)
    #expect(editor.undoManager === history)
    #expect(contentWrites == 0)
    #expect(history.canUndo)
    #expect((editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 24)
    #expect((editor.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.lineSpacing == 8)
    #expect((theme.attributes(for: .keyword, language: .swift)[.font] as? NSFont)?.pointSize == 20)
    let nextLayout = TableBlockLayout(table: table, width: 220, reusing: oldLayout)
    #expect(nextLayout.rowHeights[0] > oldLayout.rowHeights[0])
    #expect(NoteStyleSettings(defaults: defaults).values == style.values)
    history.undo()
    #expect(editor.content == original)
    history.redo()
    #expect(editor.content == content)

    editor.setSelectedRange(NSRange(location: 0, length: 0))
    history.beginUndoGrouping()
    editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    let markedRange = editor.markedRange()
    let markedText = editor.string
    style.update { $0.typography.bodySize = 18 }
    try await Task.sleep(for: .milliseconds(180))
    #expect(editor.hasMarkedText())
    #expect(editor.markedRange() == markedRange)
    #expect(editor.string == markedText)
    editor.unmarkText()
    history.endUndoGrouping()
    try await Task.sleep(for: .milliseconds(180))
    #expect(!editor.hasMarkedText())
    #expect((editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 18)

    style.update { $0.typography.bodyFamily = "No Such Foldpin Font"; $0.typography.bodySize = .nan; $0.paperOpacity = -1; $0.glassOpacity = 2 }
    #expect(style.bodyFont().pointSize == 15)
    #expect(style.values.paperOpacity == 0.2)
    #expect(style.values.glassOpacity == 1)
}
