import AppKit
import Testing
@testable import FoldpinCore

private final class CodeThemeMemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    override func string(forKey name: String) -> String? { values[name] as? String }
    override func object(forKey name: String) -> Any? { values[name] }
    override func set(_ value: Any?, forKey name: String) { values[name] = value }
}

private func themeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func themeFile(_ source: String, in directory: URL, name: String = "theme.jsonc") throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data(source.utf8).write(to: url)
    return url
}

@Test @MainActor func codeThemeJSONCScopesColorsAndFonts() throws {
    let directory = try themeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = try themeFile("""
    {
      // Comments, trailing commas and URL strings are ordinary JSONC.
      "name": "https://example.com/theme/*literal*/",
      "colors": { "editor.background": "#fff", "editor.foreground": "#123456", },
      "tokenColors": [
        { "scope": "keyword, storage", "settings": { "foreground": "#abc" } },
        { "scope": ["source.swift keyword.control"], "settings": { "foreground": "#5678", "fontStyle": "bold italic underline" } },
        { "scope": "keyword", "settings": { "foreground": "#f00" } },
      ],
    }
    """, in: directory)
    let definition = try CodeThemeLoader.load(file)
    #expect(definition.name == "https://example.com/theme/*literal*/")
    #expect(!definition.isDark)
    let style = NativeCodeTheme(light: definition).token(.keyword, language: .swift)
    let color = try #require(style.foreground.usingColorSpace(.sRGB))
    #expect(abs(color.redComponent - 85.0 / 255) < 0.001)
    #expect(abs(color.alphaComponent - 136.0 / 255) < 0.001)
    #expect(style.fontStyle == "bold italic underline")
    #expect(ThemeRGBA("#ggg") == nil && ThemeRGBA("#12") == nil && ThemeRGBA("red") == nil)
}

@Test func codeThemeTextMateAndSelfContainedExport() throws {
    let directory = try themeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source: [String: Any] = ["name": "TextMate sample", "settings": [
        ["scope": "", "settings": ["background": "#101020", "foreground": "#f0f0f0"]],
        ["scope": "comment", "settings": ["foreground": "#718096", "fontStyle": "italic"]]
    ]]
    let file = directory.appendingPathComponent("sample.tmTheme")
    try PropertyListSerialization.data(fromPropertyList: source, format: .xml, options: 0).write(to: file)
    let definition = try CodeThemeLoader.load(file)
    #expect(definition.isDark && definition.color("editor.background") == "#101020")
    let copy = directory.appendingPathComponent("copy.json")
    try definition.standardJSON().write(to: copy)
    let restored = try CodeThemeLoader.load(copy)
    #expect(restored.name == definition.name && restored.rules.count == definition.rules.count)
    #expect(restored.rules[1].settings.fontStyle == "italic")
}

@Test func codeThemeIncludesRequireFolderAndPreserveOverrides() throws {
    let directory = try themeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try themeFile("""
    {"colors":{"editor.background":"#fff","editor.foreground":"#222"},"tokenColors":[{"scope":"comment","settings":{"foreground":"#aaa"}}]}
    """, in: directory, name: "base.json")
    let file = try themeFile("""
    {"name":"Child","include":"./base.json","colors":{"editor.background":"#eee"},"tokenColors":[{"scope":"string","settings":{"foreground":"#a00"}}]}
    """, in: directory)
    #expect(throws: CodeThemeError.companionFolderRequired) { try CodeThemeLoader.load(file) }
    let definition = try CodeThemeLoader.load(file, allowedDirectory: directory)
    #expect(definition.name == "Child" && definition.color("editor.background") == "#eee")
    #expect(definition.color("editor.foreground") == "#222" && definition.rules.count == 2)
    let saved = directory.appendingPathComponent("saved.json")
    try definition.standardJSON().write(to: saved)
    try FileManager.default.removeItem(at: directory.appendingPathComponent("base.json"))
    #expect(try CodeThemeLoader.load(saved).rules.count == 2)
}

@Test func codeThemeRejectsCyclesEscapesAndUnrelatedFiles() throws {
    let directory = try themeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cycle = try themeFile("{\"include\":\"theme.jsonc\"}", in: directory)
    #expect(throws: CodeThemeError.includeCycle) { try CodeThemeLoader.load(cycle, allowedDirectory: directory) }
    let escape = try themeFile("{\"include\":\"../outside.json\"}", in: directory)
    #expect(throws: CodeThemeError.outsideFolder) { try CodeThemeLoader.load(escape, allowedDirectory: directory) }
    let external = try themeFile("{\"include\":\"https://example.com/theme.json\"}", in: directory)
    #expect(throws: CodeThemeError.outsideFolder) { try CodeThemeLoader.load(external, allowedDirectory: directory) }
    let unrelated = try themeFile("{\"name\":\"package\",\"version\":\"1.0\"}", in: directory)
    #expect(throws: CodeThemeError.noColors) { try CodeThemeLoader.load(unrelated) }
    let huge = try themeFile(String(repeating: " ", count: CodeThemeLoader.maximumFileBytes + 1), in: directory)
    #expect(throws: CodeThemeError.tooLarge) { try CodeThemeLoader.load(huge) }
}

@Test @MainActor func codeThemeBuiltinsImportsPersistenceAndRemoval() throws {
    let directory = try themeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = CodeThemeMemoryDefaults()
    let library = directory.appendingPathComponent("library")
    let settings = CodeThemeSettings(defaults: defaults, directory: library)
    #expect(settings.choices.count == 6)
    let definition = try CodeThemeLoader.load(themeFile("{\"name\":\"My Theme\",\"colors\":{\"editor.background\":\"#123\"}}", in: directory))
    try settings.install(definition)
    #expect(settings.selectedIsImported && settings.choices.count == 7)
    let id = settings.selection
    try settings.install(definition)
    #expect(settings.selection == id && settings.choices.count == 7)
    let reopened = CodeThemeSettings(defaults: defaults, directory: library)
    #expect(reopened.selection == id && reopened.choices.count == 7)
    try reopened.removeSelectedImport()
    #expect(reopened.selection == "github" && reopened.choices.count == 6)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("theme.jsonc").path))
    let blocked = CodeThemeSettings(defaults: CodeThemeMemoryDefaults(), directory: directory.appendingPathComponent("theme.jsonc"))
    #expect(throws: CodeThemeError.storage) { try blocked.install(definition) }
    #expect(blocked.selection == "github")
}

@Test @MainActor func codeThemeFixedPaletteStaysReadableAcrossAppAppearances() throws {
    let definition = CodeThemeDefinition(name: "Dark surface", colors: ["editor.background": "#101010"], rules: [])
    let theme = NativeCodeTheme(light: definition)
    var carets: [NSColor] = []
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        try #require(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
            let caret = theme.caret.usingColorSpace(.sRGB)!
            carets.append(caret)
            #expect(caret.redComponent > 0.8 && caret.greenComponent > 0.8)
            #expect(theme.background.usingColorSpace(.sRGB)!.redComponent < 0.1)
        }
    }
    #expect(carets[0] == carets[1])
}

@MainActor private final class CodeThemeUndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}

@Test @MainActor func codeBackgroundOpacityPersistsAndMultipliesThemeAlpha() throws {
    let directory = try themeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = CodeThemeMemoryDefaults()
    let settings = CodeThemeSettings(defaults: defaults, directory: directory)
    #expect(settings.backgroundOpacity == 1)
    try settings.install(CodeThemeDefinition(name: "Translucent code", colors: ["editor.background": "#12345680"], rules: []))
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.frame = NSRect(x: 0, y: 0, width: 420, height: 160)
    editor.textContainerInset = NSSize(width: 20, height: 16)
    editor.textContainer?.size = NSSize(width: 380, height: CGFloat.greatestFiniteMagnitude)
    editor.codeThemes = settings
    editor.isRichText = true
    editor.configure(content: NoteContent(blocks: [NoteBlock(kind: .code, text: "sample", language: .plain)]))
    let manager = try #require(editor.textLayoutManager)
    manager.ensureLayout(for: try #require(manager.textContentManager?.documentRange))
    let rect = try #require(editor.codeBlockBackgroundRects().first)
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        editor.appearance = NSAppearance(named: appearance)
        for opacity in [1.0, 0.4, 0.0] {
            settings.setBackgroundOpacity(opacity)
            // The first display may fit NSTextView's height to its content.
            // Sample using the captured bounds, not the view's resized bounds.
            let capturedBounds = editor.bounds
            let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: capturedBounds))
            editor.cacheDisplay(in: capturedBounds, to: bitmap)
            // Interior, away from text and the border. Theme alpha must multiply
            // the preference, including a fully clear fill at zero.
            let x = Int((rect.maxX - 12) * CGFloat(bitmap.pixelsWide) / capturedBounds.width)
            let y = Int(rect.midY * CGFloat(bitmap.pixelsHigh) / capturedBounds.height)
            let alpha = try #require(bitmap.colorAt(x: x, y: y)).alphaComponent
            #expect(abs(alpha - opacity * 128 / 255) < 0.015, "\(appearance.rawValue), opacity \(opacity), actual alpha \(alpha), rect \(rect), bounds \(editor.bounds)")
        }
    }
    let reopened = CodeThemeSettings(defaults: defaults, directory: directory)
    #expect(reopened.backgroundOpacity == 0 && reopened.selection == settings.selection)
    reopened.setBackgroundOpacity(0.65)
    reopened.select("github")
    #expect(CodeThemeSettings(defaults: defaults, directory: directory).backgroundOpacity == 0.65)
}

@Test @MainActor func codeThemeChangesPreserveEditorUndoAndComposition() async throws {
    let directory = try themeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = CodeThemeSettings(defaults: CodeThemeMemoryDefaults(), directory: directory)
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.codeThemes = settings
    editor.frame = NSRect(x: 0, y: 0, width: 420, height: 160)
    editor.isRichText = true
    editor.allowsUndo = true
    let delegate = CodeThemeUndoDelegate()
    delegate.history.groupsByEvent = false
    editor.delegate = delegate
    editor.configure(content: NoteContent(blocks: [NoteBlock(kind: .code, text: "const a = 1;", language: .javascript)]))
    delegate.history.beginUndoGrouping()
    editor.insertText(" // note", replacementRange: editor.selectedRange())
    delegate.history.endUndoGrouping()
    await editor.syntaxTask?.value
    let content = editor.content, selection = editor.selectedRange()
    var publications = 0
    editor.onContentChange = { _ in publications += 1 }
    let styled = editor.attributedString()
    settings.setBackgroundOpacity(0.4)
    // A windowless NSView does not retain display invalidation. Verify the
    // preserved editing state here; the separate bitmap check covers painting.
    #expect(editor.attributedString().isEqual(to: styled))
    #expect(editor.content == content && editor.selectedRange() == selection && publications == 0)
    settings.select("dark_plus")
    #expect(editor.content == content && editor.selectedRange() == selection && publications == 0)
    #expect(editor.insertionPointColor == settings.theme.caret)
    #expect(editor.attributedString().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == settings.theme.token(.keyword, language: .javascript).foreground)
    delegate.history.undo()
    #expect(editor.content.blocks[0].text == "const a = 1;")
    delegate.history.redo()
    #expect(editor.content == content)
    delegate.history.beginUndoGrouping()
    editor.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
    delegate.history.endUndoGrouping()
    let marked = editor.markedRange()
    let draft = editor.attributedString()
    settings.setBackgroundOpacity(0)
    #expect(editor.markedRange() == marked && editor.attributedString().isEqual(to: draft))
    settings.select("monokai-color-theme")
    #expect(editor.markedRange() == marked && editor.attributedString().isEqual(to: draft))
    editor.unmarkText()
    await editor.syntaxTask?.value
    #expect(editor.attributedString().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == settings.theme.token(.keyword, language: .javascript).foreground)
    #expect(editor.insertionPointColor == settings.theme.caret)
}
