import AppKit
import SwiftUI
import Testing
@testable import FoldpinCore

/// A solid ink mark must stay opaque while only the paper behind it fades.
@MainActor private final class PaperInkSampleView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        NSRect(x: bounds.midX - 10, y: bounds.midY - 10, width: 20, height: 20).fill()
    }
}

@Test @MainActor func paperOpacityLeavesContentOpaque() throws {
    _ = NSApplication.shared
    let style = NoteStyleSettings.shared
    let saved = style.values
    let appearance = UserDefaults.standard.object(forKey: NoteAppearance.preferenceKey)
    defer {
        style.update { $0 = saved }
        if let appearance { UserDefaults.standard.set(appearance, forKey: NoteAppearance.preferenceKey) }
        else { UserDefaults.standard.removeObject(forKey: NoteAppearance.preferenceKey) }
    }
    UserDefaults.standard.set(NoteAppearance.paper.rawValue, forKey: NoteAppearance.preferenceKey)
    let surface = NoteWindowSurface(content: PaperInkSampleView())
    surface.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
    let window = NSWindow(contentRect: surface.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = surface
    surface.layout()
    surface.layoutSubtreeIfNeeded()
    for opacity in [0.2, 1.0] {
        style.update { $0.paperOpacity = opacity }
        surface.displayIfNeeded()
        // cacheDisplay captures only this view's backing; PDF includes the
        // child view that stands in for editor text.
        let pdf = surface.dataWithPDF(inside: surface.bounds)
        let image = try #require(NSImage(data: pdf))
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 100, height: 100))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let ink = try #require(bitmap.colorAt(x: 50, y: 50))
        let background = try #require(bitmap.colorAt(x: 25, y: 25))
        #expect(ink.alphaComponent > 0.99)
        #expect(ink.brightnessComponent < 0.05)
        #expect(abs(background.alphaComponent - opacity) < 0.1)
    }
}

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
    let storedText = editor.attributedString()
    let typing = style.values.typography
    for intensity in [0.0, 0.5, 1.0] {
        style.update { $0.glassBalance = 0; $0.glassColorIntensity = intensity; $0.clearGlass.toggle() }
        #expect(editor.content == content && editor.selectedRanges == selection)
        #expect(editor.attributedString().isEqual(to: storedText))
        #expect(editor.undoManager === history && contentWrites == 0)
        #expect(style.values.typography == typing)
    }
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

    style.update { $0.typography.bodyFamily = "No Such Foldpin Font"; $0.typography.bodySize = .nan; $0.paperOpacity = -1; $0.glassBalance = 2 }
    #expect(style.bodyFont().pointSize == 15)
    #expect(style.values.paperOpacity == 0.2)
    #expect(style.values.glassBalance == 1)
}

@Test @MainActor func appearanceSurfaceLayoutSamples() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLDPIN_CHECK_OUTPUT"]!)
    let previous = UserDefaults.standard.object(forKey: NoteAppearance.preferenceKey)
    let style = NoteStyleSettings.shared
    let saved = style.values
    defer {
        if let previous { UserDefaults.standard.set(previous, forKey: NoteAppearance.preferenceKey) }
        else { UserDefaults.standard.removeObject(forKey: NoteAppearance.preferenceKey) }
        style.update { $0 = saved }
    }
    UserDefaults.standard.set(NoteAppearance.translucent.rawValue, forKey: NoteAppearance.preferenceKey)
    let content = NSView()
    let surface = NoteWindowSurface(content: content)
    surface.updateColor(.blue)
    let glass = try #require(surface.subviews.compactMap { $0 as? NSGlassEffectView }.first)
    #expect(content.superview === surface && glass.contentView != nil && glass.contentView !== content)
    for balance in [-1.0, -0.5, 0, 0.5, 1] {
        style.update { $0.glassBalance = balance }
        #expect(abs(glass.alphaValue - style.values.nativeGlassOpacity) < 0.001)
        #expect(content.alphaValue == 1 && content.superview === surface)
    }
    for intensity in [0.0, 0.5, 1.0] {
        style.update { $0.glassColorIntensity = intensity; $0.clearGlass = intensity == 0 }
        #expect((glass.tintColor == nil) == (intensity == 0))
        #expect(glass.style == (intensity == 0 ? .clear : .regular))
        #expect(surface.color == .blue)
        #expect(content.superview != nil)
    }
    for (language, tag) in [(AppLanguage.english, "en"), (.simplifiedChinese, "zh")] {
        LanguageSettings.shared.select(language)
        for dark in [false, true] {
            NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            style.update { $0.glassBalance = 0; $0.glassColorIntensity = dark ? 0 : 1 }
            let host = NSHostingView(rootView: AppearanceSettingsView().environment(\.locale, LanguageSettings.shared.locale))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 950), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            for _ in 0..<8 { try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded() }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("appearance-\(tag)-\(dark ? "dark" : "light").png"))
            #expect(!window.isVisible)
            window.contentView = nil
        }
    }
}

@Test @MainActor func noteDensityKeepsMixedEditorAndTableSession() async throws {
    _ = NSApplication.shared
    let style = NoteStyleSettings.shared
    let saved = style.values
    defer { style.update { $0 = saved } }
    style.update { $0.contentDensity = .standard }
    let table = NoteBlock(kind: .table, table: NoteTable(rows: [["Name", "Value"], ["Foldpin", "1"]]))
    let note = NoteContent(blocks: [
        NoteBlock(text: "First paragraph"), NoteBlock(kind: .task, text: "Follow up"),
        NoteBlock(kind: .code, text: "let x = 1", language: .swift), table, NoteBlock(text: "After table")
    ])
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.frame = NSRect(x: 0, y: 0, width: 460, height: 560)
    editor.textContainer?.containerSize = NSSize(width: 396, height: CGFloat.greatestFiniteMagnitude)
    editor.isRichText = true
    editor.isEditable = true
    editor.allowsUndo = true
    let undo = UndoManager(); undo.groupsByEvent = false; editor.sessionUndoManager = undo
    editor.configure(content: note)
    let scroll = NSScrollView(frame: editor.frame); scroll.documentView = editor
    let window = NSWindow(contentRect: editor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = scroll
    defer { window.contentView = nil }
    editor.setSelectedRange(NSRange(location: 3, length: 0))
    let text = editor.string
    var writes = 0; editor.onContentChange = { _ in writes += 1 }
    editor.beginTableCellEditing(blockID: table.id, row: 0, column: 0)
    let cell = try #require(editor.tableCellEditor)
    // Entering a cell deliberately moves the host selection to its attachment.
    let selection = editor.selectedRanges
    for density: NoteContentDensity in [.compact, .comfortable, .standard] {
        style.update { $0.contentDensity = density }
        try await Task.sleep(for: .milliseconds(180))
        #expect(editor.content == note && editor.string == text && writes == 0)
        #expect(editor.selectedRanges == selection && editor.undoManager === undo)
        #expect(editor.tableCellEditor === cell && cell.string == "Name")
        #expect(editor.textContainerInset.height == density.editorVerticalInset)
        let spacing = (editor.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing
        #expect(spacing == density.blockSpacing)
        #expect(editor.blockSurfaces().count == note.blocks.count)
        #expect(editor.tableFrame(blockID: table.id) != nil)
    }
    #expect(editor.blockSurfaces().first?.rect != nil)
}
