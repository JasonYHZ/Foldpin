import AppKit
import Testing
@testable import FoldpinCore

@Test func syntaxEngineLoadsEveryBundledLanguageAndPreservesUnicodeRanges() async throws {
    let examples: [(CodeLanguage, String)] = [
        (.html, "<!DOCTYPE html><div title=\"🌿\">中文</div>"),
        (.swift, "import Foundation\nfunc greet() -> String { return \"🌿\" }"),
        (.java, "package example; public class Main { int count = 42; }"),
        (.javascript, "const emoji = '🌿'; function greet() { return 42; }"),
        (.typescript, "interface User { name: string; } const count: number = 42;"),
        (.python, "def greet():\n    return '🌿'"),
        (.json, "{\"emoji\": \"🌿\", \"count\": 42}"),
        (.sql, "SELECT name FROM users WHERE id = 42;"),
        (.shell, "#!/bin/bash\necho \"🌿\""),
        (.css, ".card { color: #ff0000; display: flex; }"),
        (.c, "#include <stdio.h>\nint main(void) { return 0; }"),
        (.cpp, "#include <iostream>\nint main() { std::cout << 42; }"),
        (.csharp, "using System; public class Card { public int Count = 42; }"),
        (.go, "package main\nimport \"fmt\"\nfunc main() { fmt.Println(42) }"),
        (.rust, "fn main() { let mut count: usize = 42; println!(\"{}\", count); }"),
        (.kotlin, "data class User(val name: String)\nfun main() { println(42) }"),
        (.ruby, "def greet(name)\n  puts \"Hello #{name}\"\nend"),
        (.php, "<?php function greet() { echo '🌿'; } ?>"),
        (.yaml, "name: Foldpin\nenabled: true\nitems:\n  - one"),
        (.markdown, "# Title\n\n**Bold** and `code`"),
        (.diff, "@@ -1 +1 @@\n-old\n+new"),
        (.ini, "[editor]\nname = \"Foldpin\"\nenabled = true"),
        (.objectivec, "#import <Foundation/Foundation.h>\n@interface Card : NSObject\n@end"),
        (.lua, "local count = 42\nfunction greet() return count end"),
        (.dart, "void main() { final name = 'Foldpin'; print(name); }"),
        (.r, "data <- c(1, 2, 3)\nprint(mean(data))"),
        (.makefile, "all: build\n\techo \"Foldpin\""),
        (.dockerfile, "FROM alpine:3\nRUN echo Foldpin\nWORKDIR /app"),
        (.graphql, "query User { user(id: 42) { name email } }")
    ]
    #expect(Set(examples.map(\.0)) == Set(CodeLanguage.allCases.filter { $0 != .plain && $0 != .automatic }))
    let engine = CodeSyntaxEngine()
    for (language, sample) in examples {
        let source = sample + "\r\n"
        let result = await engine.analyze(source, language: language)
        #expect(result.language == language, Comment(rawValue: language.rawValue))
        #expect(!result.spans.isEmpty, Comment(rawValue: language.rawValue))
        var previousEnd = 0
        for span in result.spans {
            #expect(span.range.location >= previousEnd)
            #expect(NSMaxRange(span.range) <= source.utf16.count)
            #expect(Range(span.range, in: source) != nil) // Never split a surrogate pair.
            previousEnd = NSMaxRange(span.range)
        }
        #expect(engine.cached(source, language: language)?.spans.count == result.spans.count)
        let content = NoteContent(blocks: [NoteBlock(kind: .code, text: source, language: language)])
        #expect(try JSONDecoder().decode(NoteContent.self, from: JSONEncoder().encode(content)) == content)
        #expect(MarkdownBlockShortcut.match(prefix: "```" + language.rawValue, trigger: .space)?.language == language)
    }
}

@Test func syntaxEngineBoundsWorkAndUnderstandsEmbeddedLanguages() async {
    let engine = CodeSyntaxEngine()
    let long = String(repeating: "x", count: CodeSyntaxEngine.maximumSourceLength)
    #expect(await engine.analyze(long, language: .java).spans.isEmpty)
    #expect(await engine.analyze("const n = 42;", language: .plain).spans.isEmpty)
    let html = "<style>.card { color: red; }</style><script>const n = 42;</script><script type='application/ld+json'>{\"ok\":true}</script>"
    let result = await engine.analyze(html, language: .html)
    #expect(result.spans.contains { $0.language == .css && $0.scope == "attribute" })
    #expect(result.spans.contains { $0.language == .javascript && $0.scope == "keyword" })
    #expect(result.spans.contains { $0.language == .json && $0.scope == "keyword" })
    // Strings containing runnable-looking JavaScript remain source data.
    let literal = "const source = 'globalThis.pwned = true; <div>🌿</div>';"
    let parsed = await engine.analyze(literal, language: .javascript)
    #expect(parsed.spans.contains { $0.scope == "string" && (literal as NSString).substring(with: $0.range).contains("globalThis") })
}

@MainActor private final class SyntaxUndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}

@Test @MainActor func syntaxEngineAsyncRefreshRejectsStaleTextAndKeepsUndoSelectionAndIME() async {
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.isRichText = true
    editor.allowsUndo = true
    let delegate = SyntaxUndoDelegate()
    delegate.history.groupsByEvent = false
    editor.delegate = delegate
    editor.configure(content: NoteContent(blocks: [NoteBlock(kind: .code, text: "public class Old {}", language: .java)]))
    let obsolete = editor.syntaxTask
    delegate.history.beginUndoGrouping()
    editor.insertText("public class Fresh { int count = 91827; }", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    delegate.history.endUndoGrouping()
    let current = editor.content
    let selection = NSRange(location: 13, length: 5)
    editor.setSelectedRange(selection)
    var publications = 0
    editor.onContentChange = { _ in publications += 1 }
    await obsolete?.value
    await editor.syntaxTask?.value
    #expect(editor.content == current && editor.selectedRange() == selection && publications == 0)
    #expect(editor.attributedString().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == editor.codeThemes.theme.token(.keyword, language: .java).foreground)
    delegate.history.undo()
    #expect(editor.string == "public class Old {}")
    delegate.history.redo()
    #expect(editor.content == current)
    delegate.history.beginUndoGrouping()
    editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
    delegate.history.endUndoGrouping()
    let draft = editor.attributedString(), marked = editor.markedRange()
    await editor.syntaxTask?.value
    #expect(editor.hasMarkedText() && editor.markedRange() == marked && editor.attributedString().isEqual(to: draft))
    editor.unmarkText()
    let finalized = editor.content
    await editor.syntaxTask?.value
    #expect(editor.content == finalized && !editor.hasMarkedText())
}

@Test @MainActor func syntaxEngineKeepsExistingColorsWhileTypingAndLanguageChangesWin() async {
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.isRichText = true
    let code = NoteBlock(kind: .code, text: "const pending = 732691;", language: .javascript)
    editor.configure(content: NoteContent(blocks: [code]))
    await editor.syntaxTask?.value
    let color = editor.attributedString().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    #expect(color == editor.codeThemes.theme.token(.keyword, language: .javascript).foreground)
    editor.insertText(" // pending grammar result", replacementRange: editor.selectedRange())
    #expect(editor.attributedString().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == color)
    let pending = editor.syntaxTask
    editor.setCodeLanguage(.plain, blockID: code.id)
    let content = editor.content, selection = editor.selectedRange()
    await pending?.value
    await editor.syntaxTask?.value
    #expect(editor.content == content && editor.selectedRange() == selection)
    #expect(editor.attributedString().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == editor.codeThemes.theme.foreground)
}
