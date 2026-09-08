import AppKit
import Testing
@testable import FoldpinCore

private final class MemoryThemeDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: String] = [:]
    override func string(forKey defaultName: String) -> String? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value as? String }
    override func removeObject(forKey defaultName: String) { values.removeValue(forKey: defaultName) }
}

@MainActor private final class ThemeUndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}

@Test @MainActor func themePreferenceAppliesImmediatelyRemembersAndFollowsSystem() {
    let defaults = MemoryThemeDefaults()
    defaults.set("translucent", forKey: "noteAppearance")
    var applied: [NSAppearance.Name?] = []
    let settings = ThemeSettings(defaults: defaults, applyAppearance: { applied.append($0?.name) })
    #expect(settings.selection == .system)
    settings.apply()
    #expect(applied.count == 1 && applied[0] == nil)
    settings.select(.dark)
    #expect(applied.last! == .darkAqua)
    #expect(ThemeSettings(defaults: defaults, applyAppearance: { _ in }).selection == .dark)
    settings.select(.light)
    #expect(applied.last! == .aqua)
    settings.select(.system)
    #expect(applied.count == 4 && applied.last! == nil)
    #expect(defaults.string(forKey: ThemeSettings.preferenceKey) == nil)
    #expect(defaults.string(forKey: "noteAppearance") == "translucent")
    defaults.set("unknown", forKey: ThemeSettings.preferenceKey)
    #expect(ThemeSettings(defaults: defaults, applyAppearance: { _ in }).selection == .system)
}

@Test @MainActor func themeSwitchPreservesContentSelectionUndoAndComposition() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 300))
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.frame = root.bounds
    root.addSubview(editor)
    editor.isRichText = true
    editor.configure(content: NoteContent(blocks: [NoteBlock(kind: .code, text: "let a = 1", language: .swift), NoteBlock()]))
    let delegate = ThemeUndoDelegate()
    delegate.history.groupsByEvent = false
    editor.delegate = delegate
    editor.allowsUndo = true
    delegate.history.beginUndoGrouping()
    editor.insertText("正文", replacementRange: editor.selectedRange())
    delegate.history.endUndoGrouping()
    let content = editor.content
    let selection = editor.selectedRange()
    var publications = 0
    editor.onContentChange = { _ in publications += 1 }
    let theme = ThemeSettings(defaults: MemoryThemeDefaults(), applyAppearance: { root.appearance = $0 })
    theme.select(.dark)
    #expect(editor.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    theme.select(.light)
    #expect(editor.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
    #expect(editor.content == content && editor.selectedRange() == selection)
    #expect(publications == 0)
    delegate.history.undo()
    #expect(editor.content.blocks.last?.text == "")
    delegate.history.redo()
    #expect(editor.content == content)
    delegate.history.beginUndoGrouping()
    editor.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
    delegate.history.endUndoGrouping()
    let marked = editor.markedRange()
    let draft = editor.content
    let count = publications
    theme.select(.dark)
    #expect(editor.hasMarkedText() && editor.markedRange() == marked)
    #expect(editor.content == draft && publications == count)
    theme.select(.system)
    #expect(root.appearance == nil)
}

@Test @MainActor func githubCodeColorsKeepStringsCommentsAndStructuredContentIntact() {
    let code = "const url = \"https://example.com/#tag\"; // return 123\nfunction greet() { return 42; }"
    let content = NoteContent(blocks: [NoteBlock(kind: .code, text: code, language: .javascript)])
    let rendered = BlockTextCodec.render(content, color: .labelColor, width: 320, image: { _ in nil })
    func color(_ sample: String) -> NSColor? {
        rendered.attribute(.foregroundColor, at: (code as NSString).range(of: sample).location, effectiveRange: nil) as? NSColor
    }
    #expect(color("const") == GitHubCodeTheme.keyword)
    #expect(color("https://") == GitHubCodeTheme.string)
    #expect(color("#tag") == GitHubCodeTheme.string)
    #expect(color("return 123") == GitHubCodeTheme.comment)
    #expect(color("greet") == GitHubCodeTheme.function)
    #expect(color("42") == GitHubCodeTheme.constant)
    #expect(rendered.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
    #expect(NoteContent(blocks: BlockTextCodec.read(rendered, typing: [:]).map(\.block)) == content)
    var light: NSColor?
    var dark: NSColor?
    NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { light = GitHubCodeTheme.background.usingColorSpace(.sRGB) }
    NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { dark = GitHubCodeTheme.background.usingColorSpace(.sRGB) }
    #expect(light != dark)
}

@MainActor private final class ThemePreviewSurface: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NotePalette.paperBackground.setFill()
        dirtyRect.fill()
    }
}

@Test @MainActor func githubCodeSurfacesCoverWrappedAndEmptyLinesInBothThemes() throws {
    let root = ThemePreviewSurface(frame: NSRect(x: 0, y: 0, width: 380, height: 520))
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.isRichText = true
    editor.frame = root.bounds
    editor.textContainerInset = NSSize(width: 20, height: 20)
    editor.textContainer?.size = NSSize(width: 340, height: 100_000)
    editor.textContainer?.widthTracksTextView = true
    editor.textContainer?.lineFragmentPadding = 0
    root.addSubview(editor)
    let content = NoteContent(blocks: [
        NoteBlock(kind: .heading, text: "GitHub · Native code"),
        NoteBlock(text: "正文与代码分开显示 / Local, editable text"),
        NoteBlock(kind: .code, text: "// A small note, always nearby\nconst url = \"https://github.com/primer\";\n\nfunction greet(name) {\n  return `Hello, ${name}!`;\n}\ngreet(\"Foldpin\");", language: .javascript),
        NoteBlock(text: "下面是空代码块；⌘Return 回到正文。"),
        NoteBlock(kind: .code),
        NoteBlock(text: "继续写下一个想法。")
    ])
    editor.noteColor = NotePalette.paperText
    editor.configure(content: content)
    #expect(!editor.usesAdaptiveColorMappingForDarkAppearance)
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        root.appearance = NSAppearance(named: appearance)
        let manager = try #require(editor.textLayoutManager)
        manager.ensureLayout(for: try #require(manager.textContentManager?.documentRange))
        let rects = editor.codeBlockBackgroundRects()
        #expect(rects.count == 2)
        #expect(rects.allSatisfy { $0.width > 300 && $0.height >= 34 && $0.minY >= 0 })
        if rects.count == 2 { #expect(rects[0].maxY < rects[1].minY) }
        #expect(editor.content == content)
        if let folder = ProcessInfo.processInfo.environment["FOLDPIN_THEME_PREVIEW_DIR"] {
            let directory = URL(fileURLWithPath: folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("github-code-\(name).png"))
        }
    }
    // A freshly converted code block can be the entire empty document. Its
    // caret is at the viewport's end, but the block surface should still show.
    editor.configure(content: NoteContent(blocks: [NoteBlock(kind: .code)]))
    let manager = try #require(editor.textLayoutManager)
    manager.ensureLayout(for: try #require(manager.textContentManager?.documentRange))
    let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
    root.cacheDisplay(in: root.bounds, to: bitmap)
    #expect(editor.codeBlockBackgroundRects().count == 1)
}
