import AppKit
import Testing
@testable import FoldpinCore

@MainActor private final class CodeToolsUndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}

@MainActor private func codeToolsEditor(_ content: NoteContent) -> PaperTextView {
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.frame = NSRect(x: 0, y: 0, width: 440, height: 420)
    editor.textContainerInset = NSSize(width: 20, height: 20)
    editor.textContainer?.size = NSSize(width: 400, height: 100_000)
    editor.textContainer?.widthTracksTextView = true
    editor.textContainer?.lineFragmentPadding = 0
    editor.isRichText = true
    editor.configure(content: content)
    return editor
}

@Test @MainActor func htmlCodeHighlightPreservesMarkupAndHandlesEmbeddedScripts() throws {
    let code = """
    <!DOCTYPE html>
    <html lang="en"><!-- 中文 🌿 <fake> const return -->
    <meta data-value='a > b' disabled>
    <script src="https://example.com/vue.js"></script>
    <div id="root">&amp; 中文</div>
    <script>const vm = new Vue({ el: '#root', data: { count: 42 } }); // comment
    function greet() { return "<not-a-tag>"; }</script>
    <script type="application/ld+json">{"value": true}</script>
    </html>
    """
    let content = NoteContent(blocks: [NoteBlock(kind: .code, text: code, language: .html)])
    let theme = NativeCodeTheme.github
    let rendered = BlockTextCodec.render(content, color: .labelColor, width: 400, theme: theme, image: { _ in nil })
    func expectToken(_ sample: String, _ token: CodeToken, _ language: CodeLanguage = .html) {
        let range = (code as NSString).range(of: sample)
        #expect(range.location != NSNotFound)
        guard range.location != NSNotFound else { return }
        #expect(rendered.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor == theme.token(token, language: language).foreground, Comment(rawValue: sample))
    }
    expectToken("DOCTYPE", .keyword)
    expectToken("html lang", .tag)
    expectToken("lang=", .attribute)
    expectToken("<fake>", .comment)
    expectToken("a > b", .string)
    expectToken("disabled", .attribute)
    expectToken("https://", .string)
    expectToken("&amp;", .entity)
    expectToken("const vm", .keyword, .javascript)
    expectToken("42", .constant, .javascript)
    expectToken("// comment", .comment, .javascript)
    expectToken("greet", .function, .javascript)
    expectToken("<not-a-tag>", .string, .javascript)
    expectToken("true", .keyword, .json)
    #expect(rendered.string == code)
    #expect(NoteContent(blocks: BlockTextCodec.read(rendered, typing: [:]).map(\.block)) == content)
    #expect(theme.token(.tag, language: .html).foreground != theme.foreground)

    // Selecting plain text explicitly disables coloring, even for recognizable HTML.
    let plain = BlockTextCodec.render(NoteContent(blocks: [NoteBlock(kind: .code, text: code, language: .plain)]), color: .labelColor, width: 400, image: { _ in nil })
    #expect(plain.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor == theme.foreground)
}

@Test @MainActor func htmlCodeUsesPublicThemeScopesAndToleratesPartialInput() {
    let theme = NativeCodeTheme(light: CodeThemeDefinition(name: "HTML sample", colors: ["editor.foreground": "#111111"], rules: [
        ThemeTokenRule(scope: ThemeScope(["text.html entity.name.tag"]), settings: ThemeTokenSettings(foreground: "#ff0000")),
        ThemeTokenRule(scope: ThemeScope(["entity.other.attribute-name.html"]), settings: ThemeTokenSettings(foreground: "#00ff00", fontStyle: "italic"))
    ]))
    let code = "🌿 <my-element data-value=\"unfinished > <fake>"
    let rendered = BlockTextCodec.render(NoteContent(blocks: [NoteBlock(kind: .code, text: code, language: .html)]), color: .labelColor, width: 400, theme: theme, image: { _ in nil })
    let tagIndex = (code as NSString).range(of: "my-element").location
    let attributeIndex = (code as NSString).range(of: "data-value").location
    let tagColor = rendered.attribute(.foregroundColor, at: tagIndex, effectiveRange: nil) as? NSColor
    let attributeColor = rendered.attribute(.foregroundColor, at: attributeIndex, effectiveRange: nil) as? NSColor
    #expect(tagColor?.usingColorSpace(.sRGB)?.redComponent == 1)
    #expect(attributeColor?.usingColorSpace(.sRGB)?.greenComponent == 1)
    #expect(rendered.string == code)
    for partial in ["<", "</", "<!-- incomplete 🌿", "<!DOCTYPE", "<a /", "<a x=", "<a x=<b>", "<script>const x = 1", "<style>a < b</style>"] {
        let value = BlockTextCodec.render(NoteContent(blocks: [NoteBlock(kind: .code, text: partial, language: .html)]), color: .labelColor, width: 400, image: { _ in nil })
        #expect(value.string == partial)
    }
    let large = String(repeating: "<div a='x'>", count: 3_000)
    let value = BlockTextCodec.render(NoteContent(blocks: [NoteBlock(kind: .code, text: large, language: .html)]), color: .labelColor, width: 400, image: { _ in nil })
    #expect(value.string == large)
    #expect(value.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor == NativeCodeTheme.github.foreground)
}

@Test @MainActor func codeLanguageTargetsHoveredBlockPreservesSelectionAndNativeUndo() throws {
    let code = NoteBlock(kind: .code, text: "<div>🌿\r\n\t$0 中文</div>\n")
    let original = NoteContent(blocks: [NoteBlock(text: "正文光标"), code, NoteBlock(kind: .code, text: "let a = 1", language: .swift)])
    let editor = codeToolsEditor(original)
    let delegate = CodeToolsUndoDelegate()
    delegate.history.groupsByEvent = false
    editor.delegate = delegate
    editor.allowsUndo = true
    let selection = NSRange(location: 1, length: 2)
    editor.setSelectedRange(selection)
    delegate.history.beginUndoGrouping()
    editor.setCodeLanguage(.html, blockID: code.id)
    delegate.history.endUndoGrouping()
    var expected = original
    expected.blocks[1].language = .html
    #expect(editor.content == expected)
    #expect(editor.selectedRange() == selection)
    #expect(try JSONDecoder().decode(NoteContent.self, from: JSONEncoder().encode(editor.content)) == expected)
    delegate.history.undo()
    #expect(editor.content == original)
    delegate.history.redo()
    #expect(editor.content == expected)

    var copied: String?
    editor.writeCodeToPasteboard = { copied = $0; return true }
    #expect(editor.copyCode(blockID: code.id))
    #expect(copied == code.text)
    #expect(!editor.copyCode(blockID: original.blocks[0].id))
    #expect(copied == code.text)
    let before = editor.content
    editor.setCodeLanguage(.json, blockID: UUID())
    editor.setCodeLanguage(.json, blockID: original.blocks[0].id)
    #expect(editor.content == before)
}

@Test @MainActor func codeLanguageEmptyBlocksUndoAndMarkedTextArePreserved() {
    for content in [NoteContent(blocks: [NoteBlock(kind: .code)]),
                    NoteContent(blocks: [NoteBlock(text: "before"), NoteBlock(kind: .code)])] {
        let editor = codeToolsEditor(content)
        let delegate = CodeToolsUndoDelegate()
        delegate.history.groupsByEvent = false
        editor.delegate = delegate; editor.allowsUndo = true
        let id = content.blocks.last!.id
        delegate.history.beginUndoGrouping()
        editor.setCodeLanguage(.html, blockID: id)
        delegate.history.endUndoGrouping()
        #expect(editor.content.blocks.last?.language == .html)
        delegate.history.undo()
        #expect(editor.content == content)
        delegate.history.redo()
        #expect(editor.content.blocks.last?.language == .html)
    }
    let code = NoteBlock(kind: .code, text: "<div>", language: .html)
    let editor = codeToolsEditor(NoteContent(blocks: [code]))
    editor.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
    let marked = editor.markedRange(), string = editor.string
    editor.setCodeLanguage(.javascript, blockID: code.id)
    #expect(editor.hasMarkedText() && editor.markedRange() == marked && editor.string == string)
    #expect(editor.content.blocks[0].language == .html)
}

@Test @MainActor func codeHoverToolbarReusesViewAndTracksGeometryWithoutMovingCaret() throws {
    _ = NSApplication.shared // Deliver native button actions without opening a window.
    let first = NoteBlock(kind: .code, text: "<div>Hello</div>\n\n<!-- hover -->", language: .html)
    let second = NoteBlock(kind: .code, text: "const value = 42;", language: .javascript)
    let content = NoteContent(blocks: [NoteBlock(text: "正文里的光标"), first, NoteBlock(text: "中间正文"), second])
    let editor = codeToolsEditor(content)
    let scroll = NSScrollView(frame: editor.frame)
    scroll.documentView = editor
    editor.setSelectedRange(NSRange(location: 2, length: 0))
    let manager = try #require(editor.textLayoutManager)
    manager.ensureLayout(for: try #require(manager.textContentManager?.documentRange))
    let surfaces = editor.codeBlockSurfaces()
    #expect(surfaces.count == 2)
    let firstRect = try #require(surfaces.first).rect
    editor.updateCodeToolbar(at: NSPoint(x: firstRect.midX, y: firstRect.midY))
    let toolbar = try #require(editor.codeToolbar)
    #expect(!toolbar.isHidden && toolbar.blockID == first.id)
    #expect(firstRect.contains(editor.convert(toolbar.frame, from: toolbar.superview)))
    #expect(editor.selectedRange().location == 2)
    #expect(toolbar.subviews.compactMap { $0 as? NSButton }.count == 2)

    let secondRect = try #require(surfaces.last).rect
    editor.updateCodeToolbar(at: NSPoint(x: secondRect.midX, y: secondRect.midY))
    #expect(editor.codeToolbar === toolbar && toolbar.blockID == second.id && !toolbar.isHidden)
    var copied: String?
    editor.writeCodeToPasteboard = { copied = $0; return true }
    toolbar.subviews.compactMap { $0 as? NSButton }.last?.performClick(nil)
    #expect(copied == second.text)
    #expect(editor.selectedRange().location == 2 && editor.content == content)
    editor.updateCodeToolbar(at: nil)
    #expect(toolbar.isHidden)
    editor.updateCodeToolbar(at: NSPoint(x: 1, y: 1))
    #expect(toolbar.isHidden)

    if let folder = ProcessInfo.processInfo.environment["FOLDPIN_CODE_TOOLS_PREVIEW_DIR"] {
        editor.updateCodeToolbar(at: NSPoint(x: firstRect.midX, y: firstRect.midY))
        let directory = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try #require(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
        scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("code-toolbar.png"))
    }
}

@Test @MainActor func javaCodeHighlightsAndKeepsStoredLanguageAndSource() throws {
    let source = #"""
    package example;
    import java.util.List;
    public class Main {
        // return "ignored" 123
        @Override
        public String toString() { return "https://example.com"; }
        private static final long TOTAL = 1_000L;
        double ratio = 1.5e3;
        String document = """
            // literal text block
            public class Literal {}
            """;
    }
    """#
    let theme = NativeCodeTheme.github
    for language in [CodeLanguage.java, .automatic] {
        let content = NoteContent(blocks: [NoteBlock(kind: .code, text: source, language: language)])
        let rendered = BlockTextCodec.render(content, color: .labelColor, width: 400, image: { _ in nil })
        for (sample, token) in [("package", CodeToken.keyword), ("private", .keyword), ("long TOTAL", .type),
                                ("@Override", .annotation), ("Main {", .type), ("toString()", .function),
                                ("https://", .string), ("1_000L", .constant), ("1.5e3", .constant),
                                ("return \"ignored\"", .comment), ("// literal text", .string), ("public class Literal", .string)] {
            let index = (source as NSString).range(of: sample).location
            #expect(index != NSNotFound)
            #expect(rendered.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor == theme.token(token, language: .java).foreground, Comment(rawValue: sample))
        }
        #expect(rendered.string == source)
        #expect(NoteContent(blocks: BlockTextCodec.read(rendered, typing: [:]).map(\.block)) == content)
        #expect(try JSONDecoder().decode(NoteContent.self, from: JSONEncoder().encode(content)) == content)
    }
    #expect(CodeLanguage.allCases.contains(.java))
    #expect(CodeLanguage.java.title(bundle: .main) == "Java")
}

@Test @MainActor func codeHoverToolbarStaysVisibleAndPinnedThroughoutScrolling() throws {
    let block = NoteBlock(kind: .code, text: String(repeating: "System.out.println(\"line\");\n", count: 80), language: .java)
    let content = NoteContent(blocks: [block, NoteBlock(text: "End of code")])
    let editor = codeToolsEditor(content)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 240))
    scroll.documentView = editor
    let manager = try #require(editor.textLayoutManager)
    manager.ensureLayout(for: try #require(manager.textContentManager?.documentRange))
    let surface = try #require(editor.codeBlockSurfaces().first).rect
    editor.setFrameSize(NSSize(width: 440, height: surface.maxY + 500))
    editor.setSelectedRange(NSRange(location: 0, length: 0))
    let pointer = NSPoint(x: 200, y: 100)
    editor.updateCodeToolbar(at: pointer)
    let toolbar = try #require(editor.codeToolbar)
    #expect(!toolbar.isHidden && toolbar.superview === scroll)
    editor.updateTrackingAreas()
    toolbar.updateTrackingAreas()
    let options: NSTrackingArea.Options = [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect]
    let editorTracking = try #require(editor.trackingAreas.first { $0.options == options })
    let toolbarTracking = try #require(toolbar.trackingAreas.first { $0.options == options })
    var pinnedFrame: NSRect?
    for offset in [60.0, 61.5, 85.25, 140, 141.5, 220, 160, 100] {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
        // This is the frame before the queued geometry refresh. It must never
        // disappear between a bounds notification and the next display pass.
        #expect(!toolbar.isHidden)
        let documentPoint = NSPoint(x: pointer.x, y: scroll.contentView.bounds.minY + pointer.y)
        editor.updateCodeToolbar(at: documentPoint)
        #expect(editor.codeToolbar === toolbar && !toolbar.isHidden && toolbar.blockID == block.id)
        #expect(toolbar.superview === scroll)
        if let pinnedFrame { #expect(toolbar.frame == pinnedFrame) }
        else { pinnedFrame = toolbar.frame }
        editor.updateTrackingAreas()
        toolbar.updateTrackingAreas()
        #expect(editor.trackingAreas.contains { $0 === editorTracking })
        #expect(toolbar.trackingAreas.contains { $0 === toolbarTracking })
        #expect(editor.content == content && editor.selectedRange().location == 0)
    }

    // Crossing from text into the sibling overlay isn't a real hover exit.
    let insideToolbar = NSPoint(x: toolbar.frame.midX, y: toolbar.frame.midY)
    let location = scroll.convert(insideToolbar, to: nil)
    let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: location, modifierFlags: [],
                                                 timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                                 trackingNumber: 0, userData: nil))
    editor.mouseExited(with: exit)
    #expect(!toolbar.isHidden)
    editor.updateCodeToolbar(at: NSPoint(x: 1, y: 1))
    #expect(toolbar.isHidden)
    editor.updateCodeToolbar(at: NSPoint(x: pointer.x, y: scroll.contentView.bounds.minY + pointer.y))
    #expect(!toolbar.isHidden)
    editor.removeFromSuperview()
    #expect(toolbar.superview == nil)
}
