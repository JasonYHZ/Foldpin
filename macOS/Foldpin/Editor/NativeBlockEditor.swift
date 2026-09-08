import AppKit
import UniformTypeIdentifiers

enum NoteEditorStatus {
    case importingImage, insertionChanged, imageFailed

    func description(bundle: Bundle) -> String {
        switch self {
        case .importingImage: String(localized: "Importing image…", bundle: bundle)
        case .insertionChanged: String(localized: "The insertion block changed. Please insert the image again.", bundle: bundle)
        case .imageFailed: String(localized: "Could not insert image. Choose an image under 40 MB and 80 megapixels.", bundle: bundle)
        }
    }
}

final class PaperTextView: NSTextView {
    var onEscape: (() -> Void)?
    var onContentChange: ((NoteContent) -> Void)?
    var onStatusChange: ((NoteEditorStatus?) -> Void)?
    var onBlockKindChange: ((NoteBlockKind) -> Void)?
    var file: NoteFile?
    var noteColor: NSColor = .labelColor
    var content = NoteContent()
    private var spans: [NoteBlockSpan] = []
    private var applying = false
    private var observingChanges = false
    private var slashMenuScheduled = false
    private var slashMenu: SlashCommandMenu?
    var hasSlashSuggestions: Bool { slashMenu != nil }
    private var importInProgress = false
    private var suppressMarkdownShortcuts = false
    private var historyEmptyBlock: NoteBlock?
    private let images = NSCache<NSUUID, NSImage>()
    private var lastImageWidth: CGFloat = 0
    private static let pasteboardType = NSPasteboard.PasteboardType("dev.jasonyu.foldpin.blocks.v1")
    private var bundle: Bundle { LanguageSettings.shared.bundle }
    var currentBlockKind: NoteBlockKind { activeSpan?.block.kind ?? .paragraph }
    var currentBlockTitle: String { title(currentBlockKind) }
    private var isRestoringHistory: Bool { undoManager?.isUndoing == true || undoManager?.isRedoing == true }

    override var needsPanelToBecomeKey: Bool { true }

    func configure(content: NoteContent) {
        dismissSlashMenu()
        historyEmptyBlock = nil
        if !observingChanges {
            NotificationCenter.default.addObserver(self, selector: #selector(textChanged(_:)), name: NSText.didChangeNotification, object: self)
            NotificationCenter.default.addObserver(self, selector: #selector(historyChanged(_:)), name: .NSUndoManagerDidUndoChange, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(historyChanged(_:)), name: .NSUndoManagerDidRedoChange, object: nil)
            observingChanges = true
            NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: self)
        }
        applying = true
        defer { applying = false }
        images.totalCostLimit = 16 * 1_024 * 1_024
        self.content = content
        drawsBackground = false
        // The app supplies both palettes; AppKit must not invert their colors
        // a second time or rewrite them during copy/paste in dark appearance.
        usesAdaptiveColorMappingForDarkAppearance = false
        textStorage?.setAttributedString(render(content))
        typingAttributes = BlockTextCodec.style(content.blocks.last ?? NoteBlock(), color: noteColor)
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        spans = BlockTextCodec.read(attributedString(), typing: typingAttributes)
        onBlockKindChange?(currentBlockKind)
        registerForDraggedTypes([.fileURL, .png, .tiff, .string])
    }

    func loadExternalContent(_ next: NoteContent) {
        guard next != content, !hasMarkedText() else { return }
        let selection = selectedRange()
        configure(content: next)
        setSelectedRange(NSRange(location: min(selection.location, (string as NSString).length), length: 0))
        undoManager?.removeAllActions()
    }

    func updateColors(_ color: NSColor) {
        guard noteColor != color else { return }
        noteColor = color
        refreshStyles(force: true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshStyles(force: true)
        slashMenu?.updateAppearance(effectiveAppearance)
    }

    override func draw(_ dirtyRect: NSRect) {
        for rect in codeBlockBackgroundRects() where rect.intersects(dirtyRect) {
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            GitHubCodeTheme.background.setFill()
            path.fill()
            (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? NSColor.labelColor : GitHubCodeTheme.border).setStroke()
            path.lineWidth = 0.75
            path.stroke()
        }
        super.draw(dirtyRect)
    }

    func codeBlockBackgroundRects() -> [NSRect] {
        guard let manager = textLayoutManager, let source = manager.textContentManager else { return [] }
        let origin = textContainerOrigin
        let width = max(0, (textContainer?.size.width ?? bounds.width) - 2 * (textContainer?.lineFragmentPadding ?? 0))
        guard width > 0 else { return [] }
        return spans.compactMap { span in
            guard span.block.kind == .code,
                  let start = source.location(source.documentRange.location, offsetBy: span.textRange.location),
                  let end = source.location(start, offsetBy: span.textRange.length),
                  let range = NSTextRange(location: start, end: end) else { return nil }
            // Skip off-screen blocks when TextKit has a viewport. Keep the
            // range intact so wrapping and blank code lines share one surface.
            if let viewport = manager.textViewportLayoutController.viewportRange,
               !viewport.intersects(range), !viewport.contains(start),
               !(range.isEmpty && start.compare(viewport.endLocation) == .orderedSame) { return nil }
            var top = CGFloat.infinity
            var bottom = -CGFloat.infinity
            manager.enumerateTextSegments(in: range, type: .standard, options: .rangeNotRequired) { _, rect, _, _ in
                top = min(top, rect.minY)
                bottom = max(bottom, rect.maxY)
                return true
            }
            guard top.isFinite, bottom.isFinite else { return nil }
            return NSRect(x: origin.x + (textContainer?.lineFragmentPadding ?? 0), y: origin.y + top - 7,
                          width: width, height: max(20, bottom - top) + 14)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(newSize.width - lastImageWidth) > 8 {
            lastImageWidth = newSize.width
            refreshStyles(force: true, imagesOnly: true)
        }
    }

    private func render(_ value: NoteContent) -> NSAttributedString {
        BlockTextCodec.render(value, color: noteColor, width: max(80, bounds.width - textContainerInset.width * 2)) { [weak self] asset in
            guard let self else { return nil }
            if let cached = images.object(forKey: asset.id as NSUUID) { return cached }
            guard let url = file?.imageURL(asset.id), let image = NSImage(contentsOf: url) else { return nil }
            images.setObject(image, forKey: asset.id as NSUUID, cost: asset.pixelWidth * asset.pixelHeight * 4)
            return image
        }
    }

    @objc private func textChanged(_ notification: Notification) {
        guard !applying else { return }
        // Deleting the entire editing surface starts a fresh paragraph. A
        // structural conversion or native undo must keep its intentional type.
        if string.isEmpty, !hasMarkedText(), !isRestoringHistory,
           spans.contains(where: { $0.range.length > 0 }) {
            var empty = NoteBlock()
            empty.id = content.blocks.first?.id ?? empty.id
            typingAttributes = BlockTextCodec.style(empty, color: noteColor)
            registerEmptyBlockHistory(before: nil, after: empty)
        }
        // Save the current composition, but do not touch its marked attributes.
        let next = BlockTextCodec.read(attributedString(), typing: typingAttributes)
        let old = content
        spans = next
        content = NoteContent(blocks: next.map(\.block))
        if !hasMarkedText() { refreshStyles(previous: old) }
        onContentChange?(content)
        scheduleSlashMenu()
    }

    @objc private func selectionChanged(_ notification: Notification) {
        // The parser catches up in textChanged after a character edit. Pure
        // cursor movement should close suggestions, not modify the document.
        if slashMenu != nil && !slashContextIsValid { dismissSlashMenu() }
        guard !applying, !hasMarkedText(), !isRestoringHistory,
              spans.last.map({ NSMaxRange($0.range) }) == (string as NSString).length else { return }
        updateTypingStyle()
    }

    @objc private func historyChanged(_ notification: Notification) {
        guard let history = notification.object as? UndoManager, history === undoManager else { return }
        // AppKit can restore its text storage without calling didChangeText,
        // notably for attribute edits. Publish only after the whole undo group.
        if string.isEmpty, let block = historyEmptyBlock {
            typingAttributes = BlockTextCodec.style(block, color: noteColor)
        }
        historyEmptyBlock = nil
        commitContent()
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        // Images are standalone blocks. Keep their paragraph boundary intact
        // when a deletion would otherwise merge text into an attachment line.
        if !applying, let replacementString, affectedCharRange.location != NSNotFound {
            let value = string as NSString
            let end = NSMaxRange(affectedCharRange)
            if affectedCharRange.location <= value.length, end <= value.length {
                let left = affectedCharRange.location > 0 ? value.substring(with: NSRange(location: affectedCharRange.location - 1, length: 1)) : "\n"
                let right = end < value.length ? value.substring(with: NSRange(location: end, length: 1)) : "\n"
                if left == "\u{fffc}" && !(replacementString.isEmpty ? right.hasPrefix("\n") : replacementString.hasPrefix("\n")) { return false }
                if right == "\u{fffc}" && !(replacementString.isEmpty ? left.hasSuffix("\n") : replacementString.hasSuffix("\n")) { return false }
            }
        }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func unmarkText() {
        super.unmarkText()
        commitContent()
    }

    func commitContent() {
        guard !applying else { return }
        spans = BlockTextCodec.read(attributedString(), typing: typingAttributes)
        content = NoteContent(blocks: spans.map(\.block))
        if !hasMarkedText() { refreshStyles(force: true) }
        onContentChange?(content)
        if !slashContextIsValid { dismissSlashMenu() }
    }

    private func refreshStyles(previous: NoteContent? = nil, force: Bool = false, imagesOnly: Bool = false) {
        guard let storage = textStorage, !applying, !hasMarkedText() else { return }
        applying = true
        defer { applying = false }
        let old = Dictionary(uniqueKeysWithValues: (previous ?? content).blocks.map { ($0.id, $0) })
        storage.beginEditing()
        for (index, span) in spans.enumerated() {
            if imagesOnly && span.block.kind != .image { continue }
            guard force || old[span.block.id] != span.block else { continue }
            let styled = NSMutableAttributedString(attributedString: render(NoteContent(blocks: [span.block])))
            if index < spans.count - 1 {
                var attrs = BlockTextCodec.style(span.block, color: noteColor)
                attrs[.blockBoundary] = true
                attrs[.nextBlock] = BlockTextCodec.metadata(spans[index + 1].block)
                styled.append(NSAttributedString(string: "\n", attributes: attrs))
            }
            guard NSMaxRange(span.range) <= storage.length,
                  styled.string == (storage.string as NSString).substring(with: span.range) else { continue }
            styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length)) { attrs, range, _ in
                storage.setAttributes(attrs, range: NSRange(location: span.range.location + range.location, length: range.length))
            }
        }
        storage.endEditing()
        updateTypingStyle()
        needsDisplay = true
    }

    private func updateTypingStyle(preservingInlineFormat: Bool = false) {
        guard !hasMarkedText(), let span = activeSpan, let storage = textStorage else { return }
        var attrs = BlockTextCodec.style(span.block, color: noteColor)
        var inline: [NSAttributedString.Key: Any] = [:]
        if preservingInlineFormat,
           typingAttributes[.blockID] as? String == span.block.id.uuidString,
           typingAttributes[.blockKind] as? String == span.block.kind.rawValue {
            inline = typingAttributes
        } else if span.textRange.length > 0 {
            let position = min(max(selectedRange().location - 1, span.textRange.location), NSMaxRange(span.textRange) - 1)
            if position < storage.length { inline = storage.attributes(at: position, effectiveRange: nil) }
        }
        if span.block.kind != .code {
            attrs[.noteBold] = inline[.noteBold]
            attrs[.noteItalic] = inline[.noteItalic]
            attrs[.font] = BlockTextCodec.font(span.block, bold: inline[.noteBold] as? Bool ?? false,
                                              italic: inline[.noteItalic] as? Bool ?? false)
        }
        // Rebuild from this block, rather than inheriting a previous code
        // line's background, language or separator metadata at its boundary.
        typingAttributes = attrs
        onBlockKindChange?(span.block.kind)
    }

    private var activeIndex: Int {
        let position = selectedRange().location
        return spans.lastIndex(where: { $0.range.location <= position }) ?? 0
    }
    private var activeSpan: NoteBlockSpan? { spans.indices.contains(activeIndex) ? spans[activeIndex] : nil }

    /// Native insertText records both text and attributes in NSTextView's undo
    /// history. Structural commands join that same history, never a second stack.
    private func replaceDocument(_ next: NoteContent, block index: Int, offset: Int = 0) {
        guard isEditable, !hasMarkedText() else { NSSound.beep(); return }
        dismissSlashMenu()
        breakUndoCoalescing()
        let rendered = render(next)
        let previousEmptyBlock = string.isEmpty ? content.blocks.first : nil
        applying = true
        super.insertText(rendered, replacementRange: NSRange(location: 0, length: (string as NSString).length))
        applying = false
        registerEmptyBlockHistory(before: previousEmptyBlock, after: rendered.length == 0 ? next.blocks.first : nil)
        typingAttributes = BlockTextCodec.style(next.blocks.last ?? NoteBlock(), color: noteColor)
        spans = BlockTextCodec.read(attributedString(), typing: typingAttributes)
        content = NoteContent(blocks: spans.map(\.block))
        if spans.indices.contains(index) {
            let span = spans[index]
            setSelectedRange(NSRange(location: span.textRange.location + min(max(0, offset), span.textRange.length), length: 0))
        }
        refreshStyles(force: true)
        onContentChange?(content)
        breakUndoCoalescing()
        scrollRangeToVisible(selectedRange())
    }

    private func registerEmptyBlockHistory(before: NoteBlock?, after: NoteBlock?) {
        guard allowsUndo, before != nil || after != nil else { return }
        // An empty attributed string cannot carry block metadata. Add it to
        // the same native undo group and restore it after AppKit finishes its
        // text operations, which can otherwise overwrite typingAttributes.
        undoManager?.registerUndo(withTarget: self) { editor in
            editor.historyEmptyBlock = before
            editor.registerEmptyBlockHistory(before: after, after: before)
        }
    }

    override func insertNewline(_ sender: Any?) {
        if !hasMarkedText(), let slashMenu, slashContextIsValid {
            slashMenu.chooseSelected()
            return
        }
        guard !hasMarkedText(), let span = activeSpan else { super.insertNewline(sender); return }
        if let shortcut = markdownShortcut(trigger: .newline, replacementRange: selectedRange()) {
            applyMarkdownShortcut(shortcut.rule, blockID: shortcut.blockID, removing: shortcut.prefix)
            return
        }
        if span.block.kind == .code {
            typingAttributes = BlockTextCodec.style(span.block, color: noteColor)
            super.insertText(NSAttributedString(string: "\n", attributes: typingAttributes), replacementRange: selectedRange())
            return
        }
        var next = content
        let index = activeIndex
        if span.block.kind == .image {
            next.blocks.insert(NoteBlock(), at: index + 1)
            replaceDocument(next, block: index + 1)
            return
        }
        if span.block.text.isEmpty && [.task, .bullet, .quote].contains(span.block.kind) {
            next.blocks[index].kind = .paragraph
            replaceDocument(next, block: index)
            return
        }
        let selection = selectedRange()
        guard NSMaxRange(selection) <= NSMaxRange(span.textRange) else { super.insertNewline(sender); return }
        let offset = max(0, selection.location - span.textRange.location)
        let end = min(span.textRange.length, offset + selection.length)
        let original = span.block.text as NSString
        next.blocks[index].text = original.substring(to: offset)
        next.blocks[index].marks = clippedMarks(span.block.marks, range: NSRange(location: 0, length: offset))
        let kind: NoteBlockKind = [.task, .bullet, .quote].contains(span.block.kind) ? span.block.kind : .paragraph
        var following = NoteBlock(kind: kind, text: original.substring(from: end))
        following.marks = clippedMarks(span.block.marks, range: NSRange(location: end, length: original.length - end))
        next.blocks.insert(following, at: index + 1)
        replaceDocument(next, block: index + 1)
    }

    private func clippedMarks(_ marks: [NoteTextMark], range: NSRange) -> [NoteTextMark] {
        marks.compactMap {
            let intersection = NSIntersectionRange(NSRange(location: $0.location, length: $0.length), range)
            guard intersection.length > 0 else { return nil }
            return NoteTextMark(location: intersection.location - range.location, length: intersection.length, bold: $0.bold, italic: $0.italic)
        }
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if !applying, !hasMarkedText(), !isRestoringHistory { updateTypingStyle(preservingInlineFormat: true) }
        let insertedText = (insertString as? String) ?? (insertString as? NSAttributedString)?.string
        let shortcut = insertedText == " " ? markdownShortcut(trigger: .space, replacementRange: replacementRange) : nil
        if !applying, !hasMarkedText(), selectedRange().length == 0,
           let span = activeSpan, span.block.kind == .image {
            var next = content
            let text = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
            next.blocks.insert(NoteBlock(text: text), at: activeIndex + 1)
            replaceDocument(next, block: activeIndex + 1, offset: (text as NSString).length)
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
        if let shortcut, !hasMarkedText() {
            applyMarkdownShortcut(shortcut.rule, blockID: shortcut.blockID, removing: shortcut.prefix + " ")
        }
    }

    private func markdownShortcut(trigger: MarkdownBlockShortcut.Trigger, replacementRange: NSRange)
        -> (rule: MarkdownBlockShortcut, blockID: UUID, prefix: String)? {
        guard isEditable, !applying, !suppressMarkdownShortcuts, !hasMarkedText(),
              let span = activeSpan, span.block.kind == .paragraph || span.block.kind == .bullet else { return nil }
        let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        guard range == selectedRange(), range.length == 0, range.location >= span.textRange.location,
              range.location <= NSMaxRange(span.textRange) else { return nil }
        let offset = range.location - span.textRange.location
        // Match only a short prefix at the logical paragraph start. Wrapped
        // lines and punctuation elsewhere in prose are never input commands.
        guard offset > 0, offset <= 24 else { return nil }
        if trigger == .newline && offset != span.textRange.length { return nil }
        let prefix = (span.block.text as NSString).substring(to: offset)
        guard let rule = MarkdownBlockShortcut.match(prefix: prefix, trigger: trigger),
              span.block.kind == .paragraph || rule.kind == .task else { return nil }
        return (rule, span.block.id, prefix)
    }

    private func applyMarkdownShortcut(_ shortcut: MarkdownBlockShortcut, blockID: UUID, removing prefix: String) {
        guard !hasMarkedText(), let span = activeSpan, span.block.id == blockID,
              span.block.text.hasPrefix(prefix) else { return }
        let index = activeIndex
        let length = (prefix as NSString).length
        let text = span.block.text as NSString
        var next = content
        next.blocks[index].kind = shortcut.kind
        next.blocks[index].text = text.substring(from: length)
        next.blocks[index].marks = shortcut.kind == .code ? [] : clippedMarks(span.block.marks, range: NSRange(location: length, length: text.length - length))
        next.blocks[index].isChecked = shortcut.isChecked
        next.blocks[index].language = shortcut.language
        replaceDocument(next, block: index)
    }

    override func deleteBackward(_ sender: Any?) {
        guard !hasMarkedText(), selectedRange().length == 0, let span = activeSpan else { super.deleteBackward(sender); return }
        if span.block.text.isEmpty, selectedRange().location == span.textRange.location,
           [.code, .heading, .subheading].contains(span.block.kind) {
            changeKind(.paragraph)
            return
        }
        if selectedRange().location == span.textRange.location, [.task, .bullet, .quote].contains(span.block.kind) {
            changeKind(.paragraph)
            return
        }
        if selectedRange().location == span.range.location, activeIndex > 0,
           spans[activeIndex - 1].block.kind == .image {
            setSelectedRange(spans[activeIndex - 1].textRange)
            return
        }
        super.deleteBackward(sender)
    }

    override func mouseDown(with event: NSEvent) {
        dismissSlashMenu()
        let position = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        if let span = spans.first(where: { $0.block.kind == .task && position >= $0.range.location && position < $0.textRange.location }) {
            window?.makeFirstResponder(self)
            setSelectedRange(NSRange(location: span.textRange.location, length: 0))
            toggleTask(nil)
            return
        }
        super.mouseDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() { super.cancelOperation(sender) }
        else if slashMenu != nil { dismissSlashMenu() }
        else { onEscape?() }
    }

    override func moveUp(_ sender: Any?) {
        if !hasMarkedText(), let slashMenu { slashMenu.moveSelection(-1) }
        else { super.moveUp(sender) }
    }

    override func moveDown(_ sender: Any?) {
        if !hasMarkedText(), let slashMenu { slashMenu.moveSelection(1) }
        else { super.moveDown(sender) }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { dismissSlashMenu() }
        return resigned
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { dismissSlashMenu() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func scrollWheel(with event: NSEvent) {
        dismissSlashMenu()
        super.scrollWheel(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "b" { toggleBold(nil); return true }
        if flags == .command, event.charactersIgnoringModifiers == "i" { toggleItalic(nil); return true }
        if flags == .command, event.keyCode == 36, activeSpan?.block.kind == .code {
            var next = content
            next.blocks.insert(NoteBlock(), at: activeIndex + 1)
            replaceDocument(next, block: activeIndex + 1)
            return true
        }
        if flags == [.command, .option], event.keyCode == 126 { moveBlock(-1); return true }
        if flags == [.command, .option], event.keyCode == 125 { moveBlock(1); return true }
        return super.performKeyEquivalent(with: event)
    }

    private var slashContextIsValid: Bool {
        guard isEditable, !hasMarkedText(), selectedRange().length == 0, let span = activeSpan,
              span.block.kind != .code, span.block.kind != .image, span.block.text == "/",
              selectedRange().location == NSMaxRange(span.textRange) else { return false }
        // Check actual storage as well: selection notifications may arrive
        // before the block parser observes a deletion or composition update.
        let text = string as NSString
        return NSMaxRange(span.textRange) <= text.length && text.substring(with: span.textRange) == "/"
    }

    private func scheduleSlashMenu() {
        guard slashContextIsValid, let span = activeSpan else { dismissSlashMenu(); return }
        if let window, !window.isKeyWindow { dismissSlashMenu(); return }
        if slashMenu?.blockID != span.block.id {
            dismissSlashMenu()
            let blockID = span.block.id
            let entries = NoteBlockKind.allCases.map { SlashCommandMenu.Entry(kind: $0, title: title($0)) }
            let suggestions = SlashCommandMenu(blockID: blockID, entries: entries)
            suggestions.onChoose = { [weak self] kind in
                guard let self else { return }
                let valid = slashContextIsValid && activeSpan?.block.id == blockID
                dismissSlashMenu()
                guard valid else { return }
                if kind == .image { chooseImage(nil) } else { changeKind(kind) }
            }
            suggestions.onDismiss = { [weak self] in self?.dismissSlashMenu() }
            slashMenu = suggestions
        }
        guard !slashMenuScheduled else { return }
        slashMenuScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            slashMenuScheduled = false
            guard slashContextIsValid, let window, window.isKeyWindow, let slashMenu else { return }
            let rect = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
            slashMenu.show(in: window, at: rect, appearance: effectiveAppearance)
        }
    }

    private func dismissSlashMenu() {
        slashMenu?.dismiss()
        slashMenu = nil
    }

    @objc func showBlockMenu(_ sender: Any?) {
        guard isEditable, !hasMarkedText() else { return }
        dismissSlashMenu()
        window?.makeFirstResponder(self)
        let rect = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        let point = window.map { convert($0.convertFromScreen(rect).origin, from: nil) } ?? NSPoint(x: 20, y: 20)
        makeBlockMenu().popUp(positioning: nil, at: point, in: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        dismissSlashMenu()
        let menu = super.menu(for: event) ?? NSMenu()
        menu.insertItem(.separator(), at: 0)
        let item = NSMenuItem(title: String(localized: "Block", bundle: bundle), action: nil, keyEquivalent: "")
        item.submenu = makeBlockMenu()
        menu.insertItem(item, at: 0)
        return menu
    }

    private func makeBlockMenu() -> NSMenu {
        let menu = NSMenu()
        for kind in NoteBlockKind.allCases where kind != .image {
            let item = NSMenuItem(title: title(kind), action: #selector(selectKind(_:)), keyEquivalent: "")
            item.representedObject = kind.rawValue
            item.target = self
            item.state = activeSpan?.block.kind == kind ? .on : .off
            menu.addItem(item)
        }
        add(menu, String(localized: "Insert Image…", bundle: bundle), #selector(chooseImage(_:)), enabled: !importInProgress)
        menu.addItem(.separator())
        add(menu, String(localized: "Bold", bundle: bundle), #selector(toggleBold(_:)), key: "b")
        add(menu, String(localized: "Italic", bundle: bundle), #selector(toggleItalic(_:)), key: "i")
        if activeSpan?.block.kind == .task {
            add(menu, String(localized: "Toggle Completed", bundle: bundle), #selector(toggleTask(_:)))
        }
        if activeSpan?.block.kind == .code {
            let item = NSMenuItem(title: String(localized: "Code Language", bundle: bundle), action: nil, keyEquivalent: "")
            let languages = NSMenu()
            for language in CodeLanguage.allCases {
                let child = NSMenuItem(title: language == .plain ? String(localized: "Plain Text", bundle: bundle) : language.rawValue,
                                       action: #selector(selectLanguage(_:)), keyEquivalent: "")
                child.target = self; child.representedObject = language.rawValue
                child.state = activeSpan?.block.language == language ? .on : .off
                languages.addItem(child)
            }
            item.submenu = languages; menu.addItem(item)
            add(menu, String(localized: "Copy Code", bundle: bundle), #selector(copyCode(_:)))
        }
        menu.addItem(.separator())
        add(menu, String(localized: "Move Block Up", bundle: bundle), #selector(moveBlockUp(_:)), enabled: activeIndex > 0)
        add(menu, String(localized: "Move Block Down", bundle: bundle), #selector(moveBlockDown(_:)), enabled: activeIndex < content.blocks.count - 1)
        add(menu, String(localized: "Duplicate Block", bundle: bundle), #selector(duplicateBlock(_:)))
        return menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "", enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; item.isEnabled = enabled
        menu.autoenablesItems = false
        menu.addItem(item)
    }

    private func title(_ kind: NoteBlockKind) -> String {
        switch kind {
        case .paragraph: String(localized: "Paragraph", bundle: bundle)
        case .heading: String(localized: "Heading 1", bundle: bundle)
        case .subheading: String(localized: "Heading 2", bundle: bundle)
        case .bullet: String(localized: "Bullet List", bundle: bundle)
        case .task: String(localized: "To-do", bundle: bundle)
        case .quote: String(localized: "Quote", bundle: bundle)
        case .code: String(localized: "Code Block", bundle: bundle)
        case .image: String(localized: "Image", bundle: bundle)
        }
    }

    @objc private func selectKind(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = NoteBlockKind(rawValue: raw) else { return }
        changeKind(kind)
    }

    private func changeKind(_ kind: NoteBlockKind) {
        guard let span = activeSpan else { return }
        var next = content
        var index = activeIndex
        if span.block.kind == .image { index += 1; next.blocks.insert(NoteBlock(), at: index) }
        next.blocks[index].kind = kind
        next.blocks[index].isChecked = false
        if slashContextIsValid { next.blocks[index].text = ""; next.blocks[index].marks = [] }
        if kind == .code { next.blocks[index].marks = [] }
        replaceDocument(next, block: index, offset: max(0, selectedRange().location - span.textRange.location))
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let language = CodeLanguage(rawValue: raw) else { return }
        var next = content
        next.blocks[activeIndex].language = language
        replaceDocument(next, block: activeIndex, offset: max(0, selectedRange().location - (activeSpan?.textRange.location ?? 0)))
    }
    @objc private func copyCode(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(activeSpan?.block.text ?? "", forType: .string)
    }
    @objc private func toggleTask(_ sender: Any?) {
        guard activeSpan?.block.kind == .task else { return }
        var next = content; next.blocks[activeIndex].isChecked.toggle()
        replaceDocument(next, block: activeIndex)
    }
    @objc private func moveBlockUp(_ sender: Any?) { moveBlock(-1) }
    @objc private func moveBlockDown(_ sender: Any?) { moveBlock(1) }
    private func moveBlock(_ delta: Int) {
        let target = activeIndex + delta
        guard content.blocks.indices.contains(target) else { return }
        var next = content; next.blocks.swapAt(activeIndex, target)
        replaceDocument(next, block: target)
    }
    @objc private func duplicateBlock(_ sender: Any?) {
        var next = content; var block = next.blocks[activeIndex]; block.id = UUID()
        next.blocks.insert(block, at: activeIndex + 1)
        replaceDocument(next, block: activeIndex + 1)
    }

    @objc private func toggleBold(_ sender: Any?) { toggleMark(.noteBold) }
    @objc private func toggleItalic(_ sender: Any?) { toggleMark(.noteItalic) }
    private func toggleMark(_ key: NSAttributedString.Key) {
        guard isEditable, !hasMarkedText(), activeSpan?.block.kind != .code, activeSpan?.block.kind != .image else { return }
        let selection = selectedRange()
        if selection.length == 0 {
            typingAttributes[key] = !(typingAttributes[key] as? Bool ?? false)
            typingAttributes[.font] = BlockTextCodec.font(activeSpan?.block ?? NoteBlock(), bold: typingAttributes[.noteBold] as? Bool ?? false,
                                                          italic: typingAttributes[.noteItalic] as? Bool ?? false)
            return
        }
        let value = NSMutableAttributedString(attributedString: attributedString().attributedSubstring(from: selection))
        let enabled = !(value.attribute(key, at: 0, effectiveRange: nil) as? Bool ?? false)
        value.addAttribute(key, value: enabled, range: NSRange(location: 0, length: value.length))
        breakUndoCoalescing()
        super.insertText(value, replacementRange: selection)
        setSelectedRange(selection)
        refreshStyles(force: true)
        breakUndoCoalescing()
    }

    override func copy(_ sender: Any?) {
        super.copy(sender)
        guard selectedRange().length > 0 else { return }
        let value = attributedString().attributedSubstring(from: selectedRange())
        let blocks = BlockTextCodec.read(value, typing: typingAttributes).map(\.block)
        if let data = try? JSONEncoder().encode(NoteContent(blocks: blocks)) {
            NSPasteboard.general.setData(data, forType: Self.pasteboardType)
        }
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        let previous = suppressMarkdownShortcuts
        suppressMarkdownShortcuts = true
        defer { suppressMarkdownShortcuts = previous }
        let board = NSPasteboard.general
        if let data = board.data(forType: Self.pasteboardType),
           var value = try? JSONDecoder().decode(NoteContent.self, from: data), (try? value.validate()) != nil {
            for index in value.blocks.indices { value.blocks[index].id = UUID() }
            if value.blocks.contains(where: { $0.image != nil }) {
                insertBlocks(value.blocks)
            } else { super.insertText(render(value), replacementRange: selectedRange()) }
            return
        }
        if importImages(from: board) { return }
        if let text = board.string(forType: .string) {
            insertPastedText(text)
        }
    }

    func insertPastedText(_ text: String) {
        guard isEditable else { return }
        let previous = suppressMarkdownShortcuts
        suppressMarkdownShortcuts = true
        defer { suppressMarkdownShortcuts = previous }
        if !hasMarkedText() { updateTypingStyle(preservingInlineFormat: true) }
        // Foreign rich text is inserted as literal text; never load remote images.
        insertText(NSAttributedString(string: text, attributes: typingAttributes), replacementRange: selectedRange())
    }

    override func pasteAsPlainText(_ sender: Any?) {
        let previous = suppressMarkdownShortcuts
        suppressMarkdownShortcuts = true
        defer { suppressMarkdownShortcuts = previous }
        super.pasteAsPlainText(sender)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let previous = suppressMarkdownShortcuts
        suppressMarkdownShortcuts = true
        defer { suppressMarkdownShortcuts = previous }
        return super.readSelection(from: pboard, type: type)
    }

    @objc private func chooseImage(_ sender: Any?) {
        guard !importInProgress, let window, let target = activeSpan?.block.id else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            self?.importImage(url: url, target: target)
        }
    }

    private func importImages(from board: NSPasteboard) -> Bool {
        guard let target = activeSpan?.block.id else { return false }
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first, let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType, type.conforms(to: .image) {
            importImage(url: url, target: target); return true
        }
        if let data = board.data(forType: .png) ?? board.data(forType: .tiff) {
            importImage(data: data, target: target); return true
        }
        return false
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ||
            sender.draggingPasteboard.availableType(from: [.png, .tiff]) != nil { return isEditable ? .copy : [] }
        return super.draggingEntered(sender)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let previous = suppressMarkdownShortcuts
        suppressMarkdownShortcuts = true
        defer { suppressMarkdownShortcuts = previous }
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        setSelectedRange(NSRange(location: index, length: 0))
        return importImages(from: sender.draggingPasteboard) || super.performDragOperation(sender)
    }

    private func importImage(url: URL? = nil, data: Data? = nil, target: UUID) {
        guard !importInProgress, let directory = file?.assetsURL else { return }
        importInProgress = true
        onStatusChange?(.importingImage)
        Task { [weak self] in
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    if let url { return try NoteImageImporter.prepare(url: url, directory: directory) }
                    return try NoteImageImporter.prepare(data: data ?? Data(), name: "image.png", directory: directory)
                }.value
                guard let self else { return }
                importInProgress = false
                guard let index = content.blocks.firstIndex(where: { $0.id == target }), !hasMarkedText() else {
                    onStatusChange?(.insertionChanged)
                    return
                }
                var next = content
                let block = NoteBlock(kind: .image, image: prepared.image)
                let replacesEmpty = next.blocks[index].text.isEmpty || next.blocks[index].text == "/"
                let destination = replacesEmpty && next.blocks[index].image == nil ? index : index + 1
                if destination == index { next.blocks[index] = block } else { next.blocks.insert(block, at: destination) }
                if destination == next.blocks.count - 1 { next.blocks.append(NoteBlock()) }
                replaceDocument(next, block: destination + 1)
                onStatusChange?(nil)
            } catch {
                guard let self else { return }
                importInProgress = false
                onStatusChange?(.imageFailed)
            }
        }
    }

    private func insertBlocks(_ blocks: [NoteBlock]) {
        var next = content
        let index = activeIndex + 1
        next.blocks.insert(contentsOf: blocks, at: index)
        replaceDocument(next, block: index)
    }
}
