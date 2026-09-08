import AppKit
import Testing
@testable import FoldpinCore

@Test func autoCodeLanguageRecognizesSupportedSnippets() {
    let examples: [(CodeLanguage, String)] = [
        (.html, "<!DOCTYPE html>\n<html lang=\"en\"><script>const vm = new Vue({});</script></html>"),
        (.html, "\n<div id=\"root\">中文 🌿</div>"),
        (.html, "<!-- a note -->\n<section>Hello</section>"),
        (.json, "{\"title\":\"Foldpin\",\"enabled\":true,\"count\":3}"),
        (.json, "[1, 2, {\"value\": null}]"),
        (.json, "{\"name\": \"unfinished"),
        (.swift, "import SwiftUI\nstruct Card: View { var body: some View { Text(\"Hi\") } }"),
        (.swift, "func greet(_ name: String) -> String { return name }"),
        (.swift, "struct User { var name: String }"),
        (.java, "public class Main { public static void main(String[] args) { System.out.println(\"Hello\"); } }"),
        (.java, "package demo;\nimport java.util.List;\nclass Names {}"),
        (.java, "@Override\npublic String toString() { return \"Hello\"; }"),
        (.java, "public record User(String name) {}"),
        (.java, "List<String> names = new ArrayList<>();"),
        (.javascript, "const vm = new Vue({ el: '#root' });"),
        (.javascript, "function greet(name) { return `Hello ${name}`; }"),
        (.javascript, "console.log('Hello');"),
        (.typescript, "interface User { name: string; }\nconst user: User = { name: 'Jason' };"),
        (.typescript, "const count: number = 1;\nconsole.log(count);"),
        (.typescript, "function greet(name: string): string { return name; }"),
        (.python, "def greet(name):\n    return f'Hello {name}'"),
        (.python, "from pathlib import Path\nprint(Path.cwd())"),
        (.python, "#!/usr/bin/env python3\nprint('Hi')"),
        (.sql, "SELECT id, name\nFROM users\nWHERE active = 1;"),
        (.sql, "insert into notes (body) values ('Hello');"),
        (.shell, "#!/bin/zsh\necho 'Hello'"),
        (.shell, "curl -L https://example.com"),
        (.shell, "git status"),
        (.shell, "echo \"Hello\"")
    ]
    for (expected, source) in examples {
        #expect(CodeLanguage.automatic.resolved(for: source) == expected, Comment(rawValue: source))
    }
}

@Test func autoCodeLanguagePrioritizesDistinctiveMarkersOverSharedKeywords() {
    let examples: [(CodeLanguage, String)] = [
        (.go, "package main\nimport \"fmt\"\nfunc main() { fmt.Println(42) }"),
        (.csharp, "using System; public class Card { public int Count = 42; }"),
        (.typescript, "namespace App { const count: number = 42; }"),
        (.php, "<?php function greet() { echo 'Hello'; } ?>"),
        (.objectivec, "#import <Foundation/Foundation.h>\n@interface Card : NSObject\n@end"),
        (.lua, "local count = 42\nfunction greet() return count end"),
        (.c, "#include <stdio.h>\nint main(void) { return 0; }"),
        (.cpp, "#include <stdio.h>\nint main() { std::cout << 42; }"),
        (.kotlin, "public class Main { fun greet() { println(42) } }"),
        (.rust, "fn main() { let mut count: usize = 42; println!(\"{}\", count); }"),
        (.dart, "void main() { final name = 'Foldpin'; print(name); }"),
        (.graphql, "query User { user(id: 42) { name email } }"),
        (.markdown, "# Title\n\n**Bold** and `code`"),
        (.diff, "@@ -1 +1 @@\n-old\n+new"),
        (.ini, "[editor]\nname = \"Foldpin\"\nenabled = true"),
        (.makefile, "all: build\n\techo \"Foldpin\""),
        (.r, "data <- c(1, 2, 3)\nprint(mean(data))")
    ]
    for (language, source) in examples {
        #expect(CodeLanguageDetector.detect(source) == language, Comment(rawValue: source))
    }
    for source in ["# Todo", "one: two", "[unfinished]", "+ one", "public class Main {}", "function greet() { return 42; }"] {
        let detected = CodeLanguageDetector.detect(source)
        #expect(![.markdown, .diff, .ini, .makefile, .r, .lua, .php].contains(detected), Comment(rawValue: source))
    }
}

@Test func autoCodeLanguageUsesIndependentSampleCacheAndStillDetectsLongBlocks() async {
    let engine = CodeSyntaxEngine()
    let first = "package demo;\npublic class Main {}\n"
    let prefix = first + String(repeating: " ", count: CodeSyntaxEngine.maximumSampleLength - first.utf16.count)
    #expect(await engine.detectLanguage(prefix + "// first version") == .java)
    let extended = prefix + String(repeating: "// more code\n", count: 2500)
    // Appending beyond the bounded sample reuses its language without running
    // grammars or generating token spans for either version.
    #expect(engine.cachedLanguage(extended) == .java)
    let longResult = await engine.analyze(extended, language: .automatic)
    #expect(longResult.language == .java && longResult.spans.isEmpty)
    #expect(engine.cached(extended, language: .automatic)?.language == .java)
    let replaced = "<!doctype html>\n" + extended
    #expect(engine.cachedLanguage(replaced) == nil)
    let replacedResult = await engine.analyze(replaced, language: .automatic)
    #expect(replacedResult.language == .html && replacedResult.spans.isEmpty)
    #expect(await engine.analyze(replaced, language: .plain).spans.isEmpty)
    #expect(await engine.analyze(replaced, language: .python).language == .python)
}

@Test func autoCodeLanguageCancelledRequestsDoNotParseOrCacheSource() async {
    let engine = CodeSyntaxEngine()
    let source = "public class Cancelled { int value = 762331; }"
    let task = Task {
        while !Task.isCancelled { await Task.yield() }
        return await engine.analyze(source, language: .automatic)
    }
    task.cancel()
    _ = await task.value
    #expect(engine.cached(source, language: .automatic) == nil)
    #expect(engine.cachedLanguage(source) == nil)
    #expect(await engine.detectLanguage(source) == .java)
}

@Test @MainActor func autoCodeLanguageToolbarDistinguishesPendingUnknownAndReady() async throws {
    let toolbar = CodeBlockToolbar()
    var block = NoteBlock(kind: .code, text: "尚无语法线索" + UUID().uuidString)
    toolbar.update(block: block, bundle: .main, theme: .github, canChangeLanguage: true)
    let button = try #require(toolbar.subviews.compactMap { $0 as? NSButton }.first)
    #expect(button.title == "Detecting…")
    _ = await CodeSyntaxEngine.shared.detectLanguage(block.text)
    toolbar.update(block: block, bundle: .main, theme: .github, canChangeLanguage: true)
    #expect(button.title == "Auto · Unknown")
    #expect(button.toolTip?.contains("Choose a language manually") == true)
    block.text = "public class Ready { int value = 674311; }"
    _ = await CodeSyntaxEngine.shared.detectLanguage(block.text)
    // Display the result before there are any token spans to render.
    #expect(CodeSyntaxEngine.shared.cached(block.text, language: .automatic) == nil)
    toolbar.update(block: block, bundle: .main, theme: .github, canChangeLanguage: true)
    #expect(button.title == "Auto · Java")
    block.language = .plain
    toolbar.update(block: block, bundle: .main, theme: .github, canChangeLanguage: true)
    #expect(button.title == "Plain Text")
}

@Test func autoCodeLanguageLeavesAmbiguousUnsupportedAndQuotedExamplesPlain() {
    let examples = ["", "随手记录一个想法", "return value", "let value = 1", "print(value)",
                    "<T>", "class Main {}", "int count = 1;",
                    "struct User { int age; };", "const MAX: usize = 10;",
                    "// const vm = new Vue({});", "/*\ndef greet(name):\n return name\n*/",
                    "\"<div>Hello</div>\"", "\"def greet(name):\"", "\"\"\"\nconst x = 1;\n\"\"\"",
                    "func greet() {}\ndef greet():\n    pass"]
    for source in examples {
        #expect(CodeLanguageDetector.detect(source) == .plain, Comment(rawValue: source))
    }
    let prefix = String(repeating: " ", count: CodeLanguageDetector.maximumSampleLength)
    #expect(CodeLanguageDetector.detect(prefix + "<div>out of sample</div>") == .plain)
    #expect(CodeLanguageDetector.detect("const template = `\n<div>Hello</div>\n`;") == .javascript)
    #expect(CodeLanguageDetector.detect("const sql = 'SELECT * FROM users';") == .javascript)
    #expect(CodeLanguageDetector.detect("const value = \"https://example.com\"; // def fake():") == .javascript)
}

@Test @MainActor func autoCodeLanguageRenderingStoresModeAndRespectsManualOverride() throws {
    let source = "<div id=\"root\">Hello 🌿</div>"
    let automatic = NoteBlock(kind: .code, text: source)
    #expect(automatic.language == .automatic)
    #expect(NoteBlock().language == .plain)
    for mode in [CodeLanguage.automatic, .html, .plain, .javascript] {
        var block = automatic
        block.language = mode
        let content = NoteContent(blocks: [block])
        let value = BlockTextCodec.render(content, color: .labelColor, width: 360, image: { _ in nil })
        let displayedColor = value.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor
        if mode == .automatic || mode == .html {
            #expect(displayedColor == NativeCodeTheme.github.token(.tag, language: .html).foreground)
        } else { #expect(displayedColor == NativeCodeTheme.github.foreground) }
        #expect(NoteContent(blocks: BlockTextCodec.read(value, typing: [:]).map(\.block)) == content)
        #expect(try JSONDecoder().decode(NoteContent.self, from: JSONEncoder().encode(content)) == content)
        #expect(value.string == source)
    }
    // Old explicit plain-text values remain plain on load; they are not migrated to auto.
    let old = NoteContent(blocks: [NoteBlock(kind: .code, text: source, language: .plain)])
    #expect(try JSONDecoder().decode(NoteContent.self, from: JSONEncoder().encode(old)).blocks[0].language == .plain)
}

@MainActor private final class AutoCodeUndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}

@Test @MainActor func autoCodeLanguageReevaluatesAfterPasteAndKeepsUndoAndComposition() async throws {
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.isRichText = true
    editor.configure(content: NoteContent(blocks: [NoteBlock(kind: .code)]))
    let delegate = AutoCodeUndoDelegate()
    delegate.history.groupsByEvent = false
    editor.delegate = delegate; editor.allowsUndo = true
    delegate.history.beginUndoGrouping()
    editor.insertPastedText("<div>Hello</div>")
    delegate.history.endUndoGrouping()
    await editor.syntaxTask?.value
    let id = editor.content.blocks[0].id
    #expect(editor.content.blocks[0].language == .automatic)
    #expect(editor.attributedString().attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor == editor.codeThemes.theme.token(.tag, language: .html).foreground)
    delegate.history.beginUndoGrouping()
    editor.insertText("const value = 42;", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
    delegate.history.endUndoGrouping()
    await editor.syntaxTask?.value
    #expect(editor.content.blocks[0].language == .automatic)
    #expect(editor.attributedString().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == editor.codeThemes.theme.token(.keyword, language: .javascript).foreground)
    delegate.history.undo()
    #expect(editor.string == "<div>Hello</div>" && editor.content.blocks[0].language == .automatic)
    delegate.history.redo()
    #expect(editor.string == "const value = 42;" && editor.content.blocks[0].id == id)
    delegate.history.beginUndoGrouping()
    editor.setCodeLanguage(.plain, blockID: id)
    delegate.history.endUndoGrouping()
    #expect(editor.content.blocks[0].language == .plain)
    #expect(editor.attributedString().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == editor.codeThemes.theme.foreground)
    delegate.history.undo()
    #expect(editor.content.blocks[0].language == .automatic)
    delegate.history.beginUndoGrouping()
    editor.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
    delegate.history.endUndoGrouping()
    let marked = editor.markedRange(), draft = editor.attributedString()
    editor.setCodeLanguage(.swift, blockID: id)
    #expect(editor.hasMarkedText() && editor.markedRange() == marked && editor.attributedString().isEqual(to: draft))
    editor.unmarkText()
    #expect(editor.content.blocks[0].language == .automatic)
    let toolbar = CodeBlockToolbar()
    toolbar.update(block: NoteBlock(kind: .code, text: "<div>Hello</div>"), bundle: .main, theme: .github, canChangeLanguage: true)
    let button = try #require(toolbar.subviews.compactMap { $0 as? NSButton }.first)
    #expect(button.title == "Auto · HTML")
    toolbar.update(block: NoteBlock(kind: .code, text: "const value = 42;"), bundle: .main, theme: .github, canChangeLanguage: true)
    #expect(button.title == "Auto · JavaScript")
    toolbar.update(block: NoteBlock(kind: .code), bundle: .main, theme: .github, canChangeLanguage: true)
    #expect(button.title == "Auto-detect")
}
