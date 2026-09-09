import AppKit
import UniformTypeIdentifiers

enum NoteEditorStatus: Equatable {
    case importingImage, insertionChanged, imageFailed, imageCopyFailed

    func description(bundle: Bundle) -> String {
        switch self {
        case .importingImage: String(localized: "Importing image…", bundle: bundle)
        case .insertionChanged: String(localized: "The insertion block changed. Please insert the image again.", bundle: bundle)
        case .imageFailed: String(localized: "Could not insert image. Choose an image under 40 MB and 80 megapixels.", bundle: bundle)
        case .imageCopyFailed: String(localized: "Could not copy image. Check that its image file is available and try again.", bundle: bundle)
        }
    }
}

final class PaperTextView: NSTextView {
    var onEscape: (() -> Void)?
    var onContentChange: ((NoteContent) -> Void)?
    var onStatusChange: ((NoteEditorStatus?) -> Void)?
    var onBlockKindChange: ((NoteBlockKind) -> Void)?
    var writeCodeToPasteboard: (String) -> Bool = { text in
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
    var writeBlockToPasteboard: (NoteContent) -> Bool = { content in
        guard let data = try? JSONEncoder().encode(content) else { return false }
        let item = NSPasteboardItem()
        item.setString(content.plainText, forType: .string)
        item.setData(data, forType: NSPasteboard.PasteboardType("dev.jasonyu.foldpin.blocks.v1"))
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([item])
    }
    var file: NoteFile?
    var writeImageToPasteboard: (NoteImage, NoteFile) throws -> Void = { image, file in
        try NoteClipboard.copyImage(image, file: file)
    }
    var codeThemes = CodeThemeSettings.shared
    var noteColor: NSColor = .labelColor
    private var paperBackground = NotePalette.paperBackground
    var content = NoteContent()
    private var spans: [NoteBlockSpan] = [] { didSet { invalidateBlockGeometry() } }
    private var tableLayouts: [UUID: TableBlockLayout] = [:]
    private var geometryCache: (bounds: NSRect, visible: NSRect, size: NSSize, origin: NSPoint,
                                padding: CGFloat, viewport: NSTextRange?, surfaces: [BlockSurface])?
    private var geometryExpiryScheduled = false
    private var editingTableCell: (id: UUID, row: Int, column: Int)?
    private(set) var tableCellEditor: TableCellTextView?
    private(set) var tableControls: TableAddControls?
    private var tableControlsUpdateScheduled = false
    private var updatingTableCell = false
    private(set) var selectedBlockID: UUID?
    private(set) var blockHandle: BlockHandleButton?
    private(set) var blockDragState: BlockDragState?
    private(set) var blockDropTarget: BlockDropTarget?
    private var blockDragLocationInWindow: NSPoint?
    private var blockDragScrollTimer: Timer?
    private var settingBlockSelection = false
    private var blockHandleUpdateScheduled = false
    private var updatingBlockHandle = false
    private var applying = false
    private var observingChanges = false
    private var insertionPointRefreshScheduled = false
    private var slashMenuScheduled = false
    private var slashMenu: SlashCommandMenu?
    private var slashMenuContext: SlashCommandContext?
    private(set) var codeToolbar: CodeBlockToolbar?
    private var codeTrackingArea: NSTrackingArea?
    private weak var observedCodeClipView: NSClipView?
    private var codeToolbarUpdateScheduled = false
    private var updatingCodeToolbar = false
    private(set) var syntaxTask: Task<Void, Never>?
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
    override var shouldDrawInsertionPoint: Bool { selectedBlockID == nil && super.shouldDrawInsertionPoint }

    func configure(content: NoteContent) {
        cancelBlockDrag()
        endTableCellEditing()
        clearBlockSelection()
        blockHandle?.isHidden = true
        dismissSlashMenu()
        codeToolbar?.isHidden = true
        tableControls?.isHidden = true
        historyEmptyBlock = nil
        if !observingChanges {
            NotificationCenter.default.addObserver(self, selector: #selector(textChanged(_:)), name: NSText.didChangeNotification, object: self)
            NotificationCenter.default.addObserver(self, selector: #selector(textStorageProcessed(_:)), name: NSTextStorage.didProcessEditingNotification, object: textStorage)
            NotificationCenter.default.addObserver(self, selector: #selector(historyChanged(_:)), name: .NSUndoManagerDidUndoChange, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(historyChanged(_:)), name: .NSUndoManagerDidRedoChange, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(codeThemeChanged(_:)), name: CodeThemeSettings.didChange, object: codeThemes)
            NotificationCenter.default.addObserver(self, selector: #selector(codeBackgroundOpacityChanged(_:)), name: CodeThemeSettings.backgroundOpacityDidChange, object: codeThemes)
            observingChanges = true
            NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: self)
            NotificationCenter.default.addObserver(self, selector: #selector(editorWindowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(editorWindowResignedKey(_:)), name: NSWindow.didResignKeyNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(editorApplicationBecameActive(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)
        }
        applying = true
        defer { applying = false }
        images.totalCostLimit = 16 * 1_024 * 1_024
        tableLayouts.removeAll()
        self.content = content
        drawsBackground = false
        // The app supplies both palettes; AppKit must not invert their colors
        // a second time or rewrite them during copy/paste in dark appearance.
        usesAdaptiveColorMappingForDarkAppearance = false
        textStorage?.setAttributedString(render(content))
        typingAttributes = BlockTextCodec.style(content.blocks.last ?? NoteBlock(), color: noteColor, theme: codeThemes.theme)
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        spans = BlockTextCodec.read(attributedString(), typing: typingAttributes)
        onBlockKindChange?(currentBlockKind)
        updateCodeCaretColors()
        registerForDraggedTypes([.fileURL, .png, .tiff, .string, BlockReordering.pasteboardType])
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
        blockHandle?.ink = color
        tableControls?.updateColors(color)
        refreshStyles(force: true)
        updateCodeCaretColors()
    }

    func updatePaperBackground(_ color: NSColor) {
        guard paperBackground != color else { return }
        paperBackground = color
        // Only the active cell paints an opaque surface. The rest of the
        // editor is transparent, so recoloring needs no syntax or layout work.
        if noteColor == NotePalette.paperText { tableCellEditor?.backgroundColor = color }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshStyles(force: true)
        slashMenu?.updateAppearance(effectiveAppearance)
        updateCodeCaretColors()
    }

    @objc private func codeThemeChanged(_ notification: Notification) {
        refreshStyles(force: true)
        updateCodeCaretColors()
        needsDisplay = true
        scheduleInsertionPointRefresh()
    }

    @objc private func codeBackgroundOpacityChanged(_ notification: Notification) {
        needsDisplay = true
    }

    private func updateCodeCaretColors() {
        guard !hasMarkedText() else { return }
        let code = currentBlockKind == .code
        insertionPointColor = code ? codeThemes.theme.caret : noteColor
        let linkColor = NotePalette.linkText(for: noteColor)
        if linkTextAttributes?[.foregroundColor] as? NSColor != linkColor {
            var attributes = linkTextAttributes ?? [:]
            attributes[.foregroundColor] = linkColor
            linkTextAttributes = attributes
        }
        selectedTextAttributes = [.backgroundColor: code ? codeThemes.theme.selection : NSColor.selectedTextBackgroundColor,
                                  .foregroundColor: code ? codeThemes.theme.selectionForeground : NSColor.selectedTextColor]
    }

    override func draw(_ dirtyRect: NSRect) {
        for rect in codeBlockBackgroundRects() where rect.intersects(dirtyRect) {
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            NSGraphicsContext.saveGraphicsState()
            // Multiply the theme's existing alpha; leave border and text untouched.
            NSGraphicsContext.current?.cgContext.setAlpha(CGFloat(codeThemes.backgroundOpacity))
            codeThemes.theme.background.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? NSColor.labelColor : codeThemes.theme.border).setStroke()
            path.lineWidth = 0.75
            path.stroke()
        }
        super.draw(dirtyRect)
        if let selectedBlockID, let surface = blockSurfaces().first(where: { $0.blockID == selectedBlockID }), surface.rect.intersects(dirtyRect) {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: surface.rect.insetBy(dx: -2, dy: -2), xRadius: 4, yRadius: 4).fill()
        }
        for placeholder in blockPlaceholders() where placeholder.rect.intersects(dirtyRect) {
            placeholder.text.draw(in: placeholder.rect)
        }
        if let target = blockDropTarget, target.indicator.intersects(dirtyRect) {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: target.indicator, xRadius: 1, yRadius: 1).fill()
            NSBezierPath(ovalIn: NSRect(x: target.indicator.minX - 2, y: target.indicator.midY - 3, width: 6, height: 6)).fill()
        }
    }

    struct BlockPlaceholder {
        let blockID: UUID
        let text: NSAttributedString
        let rect: NSRect
    }

    /// Empty-block hints are drawing only. They never enter NSTextStorage,
    /// selection, copy, undo, saved content, or the folded note title.
    func blockPlaceholders() -> [BlockPlaceholder] {
        guard isEditable, let manager = textLayoutManager, let source = manager.textContentManager else { return [] }
        let origin = textContainerOrigin
        return spans.compactMap { span in
            guard span.block.text.isEmpty, !span.block.kind.isAttachment,
                  !(hasMarkedText() && activeSpan?.block.id == span.block.id),
                  let start = source.location(source.documentRange.location, offsetBy: span.textRange.location),
                  let range = NSTextRange(location: start, end: start) else { return nil }
            if let viewport = manager.textViewportLayoutController.viewportRange,
               !viewport.contains(start), start.compare(viewport.endLocation) != .orderedSame { return nil }
            let label: String
            switch span.block.kind {
            case .paragraph:
                guard activeSpan?.block.id == span.block.id else { return nil }
                label = String(localized: "Type text or / to choose a block", bundle: bundle)
            case .heading: label = String(localized: "Heading 1", bundle: bundle)
            case .subheading: label = String(localized: "Heading 2", bundle: bundle)
            case .heading3: label = String(localized: "Heading 3", bundle: bundle)
            case .heading4: label = String(localized: "Heading 4", bundle: bundle)
            case .bullet, .orderedList: label = String(localized: "List item", bundle: bundle)
            case .task: label = String(localized: "To-do", bundle: bundle)
            case .quote: label = String(localized: "Quote", bundle: bundle)
            case .code: label = String(localized: "Type or paste code", bundle: bundle)
            case .image, .divider, .table: return nil
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let color = span.block.kind == .code
                ? codeThemes.theme.token(.comment, language: span.block.language).foreground : NotePalette.placeholderText(for: noteColor)
            let text = NSAttributedString(string: label, attributes: [
                .font: BlockTextCodec.font(span.block), .foregroundColor: color,
                .paragraphStyle: paragraph
            ])
            var segment: NSRect?
            manager.enumerateTextSegments(in: range, type: .standard, options: .rangeNotRequired) { _, rect, _, _ in
                segment = rect
                return false
            }
            guard let segment else { return nil }
            let x = origin.x + segment.minX + 2
            let trailingInset: CGFloat = span.block.kind == .code ? 12 : 0
            let width = max(0, origin.x + (textContainer?.size.width ?? bounds.width) - x - trailingInset)
            let rect = NSRect(x: x, y: origin.y + segment.minY + max(0, (segment.height - text.size().height) / 2),
                              width: width, height: text.size().height)
            return BlockPlaceholder(blockID: span.block.id, text: text, rect: rect)
        }
    }

    struct CodeBlockSurface {
        let blockID: UUID
        let rect: NSRect
    }

    func codeBlockBackgroundRects() -> [NSRect] {
        codeBlockSurfaces().map(\.rect)
    }

    func codeBlockSurfaces() -> [CodeBlockSurface] {
        let origin = textContainerOrigin
        let width = max(0, (textContainer?.size.width ?? bounds.width) - 2 * (textContainer?.lineFragmentPadding ?? 0))
        guard width > 0 else { return [] }
        let codeIDs = Set(spans.lazy.filter { $0.block.kind == .code }.map { $0.block.id })
        guard !codeIDs.isEmpty else { return [] }
        return blockSurfaces().compactMap { surface in
            guard codeIDs.contains(surface.blockID) else { return nil }
            return CodeBlockSurface(blockID: surface.blockID,
                                    rect: NSRect(x: origin.x + (textContainer?.lineFragmentPadding ?? 0), y: surface.rect.minY - 7,
                                                 width: width, height: max(20, surface.rect.height) + 14))
        }
    }

    private func invalidateBlockGeometry() { geometryCache = nil }

    @objc private func textStorageProcessed(_ notification: Notification) {
        // Includes attribute-only edits, undo and marked text, even while the
        // document model deliberately waits for an editing transaction to end.
        invalidateBlockGeometry()
    }

    override func layout() {
        invalidateBlockGeometry()
        super.layout()
        // TextKit may finalize attachment positions after the edit callback.
        // Reposition the active cell and its controls once that layout settles.
        scheduleTableControlsUpdate()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // inVisibleRect follows scrolling itself. Replacing the area on every
        // layout manufactures exit/enter pairs even when the pointer is still.
        guard codeTrackingArea == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        codeTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateCodeToolbar(at: convert(event.locationInWindow, from: nil))
        updateBlockHandle(at: convert(event.locationInWindow, from: nil))
        updateTableControls(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateCodeToolbar(at: convert(event.locationInWindow, from: nil))
        updateBlockHandle(at: convert(event.locationInWindow, from: nil))
        updateTableControls(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // Moving from text into the overlay is still inside the same code block.
        updateCodeToolbar(at: convert(event.locationInWindow, from: nil))
        updateBlockHandle(at: convert(event.locationInWindow, from: nil))
        updateTableControls(at: convert(event.locationInWindow, from: nil))
    }

    func updateCodeToolbar(at point: NSPoint?) {
        guard !updatingCodeToolbar, codeToolbar?.isPresentingMenu != true else { return }
        updatingCodeToolbar = true
        defer { updatingCodeToolbar = false }
        guard selectedBlockID == nil, let point, visibleRect.contains(point), !isHiddenOrHasHiddenAncestor,
              let surface = codeBlockSurfaces().first(where: { $0.rect.contains(point) }),
              let block = content.blocks.first(where: { $0.id == surface.blockID && $0.kind == .code }) else {
            codeToolbar?.isHidden = true
            return
        }
        let toolbar: CodeBlockToolbar
        if let existing = codeToolbar { toolbar = existing }
        else {
            toolbar = CodeBlockToolbar()
            toolbar.onSelectLanguage = { [weak self] id, language in self?.setCodeLanguage(language, blockID: id) }
            toolbar.onCopy = { [weak self] id in self?.copyCode(blockID: id) ?? false }
            toolbar.onMenuFinished = { [weak self] in self?.scheduleCodeToolbarUpdate() }
            toolbar.onPointerChange = { [weak self] point in
                guard let self else { return }
                updateCodeToolbar(at: convert(point, from: nil))
                updateBlockHandle(at: convert(point, from: nil))
            }
            codeToolbar = toolbar
        }
        // Keep chrome outside NSClipView's scrolling document. Its pinned
        // position must not first scroll away and then jump back next run loop.
        let container: NSView = enclosingScrollView ?? self
        if toolbar.superview !== container {
            toolbar.removeFromSuperview()
            container.addSubview(toolbar, positioned: .above, relativeTo: nil)
        }
        toolbar.update(block: block, bundle: bundle, theme: codeThemes.theme, canChangeLanguage: isEditable && !hasMarkedText())
        let visibleSurface = surface.rect.intersection(visibleRect)
        guard visibleSurface.width >= toolbar.frame.width + 6, visibleSurface.height >= toolbar.frame.height else {
            toolbar.isHidden = true
            return
        }
        let rect = NSRect(x: visibleSurface.maxX - toolbar.frame.width - 3,
                          y: min(visibleSurface.minY + 3, visibleSurface.maxY - toolbar.frame.height),
                          width: toolbar.frame.width, height: toolbar.frame.height)
        let frame = container.backingAlignedRect(container.convert(rect, from: self), options: .alignAllEdgesNearest)
        if toolbar.frame != frame { toolbar.frame = frame }
        if toolbar.isHidden { toolbar.isHidden = false }
    }

    func scheduleCodeToolbarUpdate() {
        scheduleBlockHandleUpdate()
        scheduleTableControlsUpdate()
        guard !codeToolbarUpdateScheduled, codeToolbar != nil else { return }
        codeToolbarUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            codeToolbarUpdateScheduled = false
            let point = window.map { self.convert($0.mouseLocationOutsideOfEventStream, from: nil) }
            updateCodeToolbar(at: point)
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        cancelBlockDrag()
        codeToolbar?.removeFromSuperview()
        blockHandle?.removeFromSuperview()
        tableControls?.removeFromSuperview()
        tableControls?.isHidden = true
        if let observedCodeClipView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedCodeClipView)
        }
        observedCodeClipView = enclosingScrollView?.contentView
        if let observedCodeClipView {
            observedCodeClipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(codeViewportChanged(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: observedCodeClipView)
        }
        updateCodeToolbar(at: nil)
        updateBlockHandle(at: nil)
    }

    @objc private func codeViewportChanged(_ notification: Notification) {
        // Coalesce geometry updates while leaving the existing overlay visible.
        // Only a confirmed pointer/block change should hide it.
        scheduleCodeToolbarUpdate()
    }

    override func setFrameSize(_ newSize: NSSize) {
        if frame.size != newSize { invalidateBlockGeometry() }
        super.setFrameSize(newSize)
        if abs(newSize.width - lastImageWidth) > 8 {
            lastImageWidth = newSize.width
            refreshStyles(force: true, imagesOnly: true)
        }
        scheduleCodeToolbarUpdate()
    }

    private func render(_ value: NoteContent, startingOrdinal: Int = 1) -> NSAttributedString {
        if value.blocks.contains(where: { $0.kind == .code && CodeSyntaxEngine.shared.cached($0.text, language: $0.language) == nil }) {
            scheduleSyntaxHighlighting()
        }
        return BlockTextCodec.render(value, color: noteColor, width: max(80, bounds.width - textContainerInset.width * 2),
                                     theme: codeThemes.theme, cachedSyntaxOnly: true, startingOrdinal: startingOrdinal,
                                     tableLayout: { [unowned self] block, width in self.tableLayout(for: block, width: width) }) { [weak self] asset in
            guard let self else { return nil }
            if let cached = images.object(forKey: asset.id as NSUUID) { return cached }
            guard let url = file?.imageURL(asset.id), let image = NSImage(contentsOf: url) else { return nil }
            images.setObject(image, forKey: asset.id as NSUUID, cost: asset.pixelWidth * asset.pixelHeight * 4)
            return image
        }
    }

    private func scheduleSyntaxHighlighting() {
        syntaxTask?.cancel()
        syntaxTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            // Snapshot without retaining the view while waiting for the engine.
            guard var blocks = self?.content.blocks else { return }
            let engine = CodeSyntaxEngine.shared
            blocks.removeAll { $0.kind != .code || engine.cached($0.text, language: $0.language) != nil }
            if let activeID = self?.activeSpan?.block.id,
               let index = blocks.firstIndex(where: { $0.id == activeID }) {
                blocks.insert(blocks.remove(at: index), at: 0)
            }
            for block in blocks {
                guard !Task.isCancelled else { return }
                if block.language == .automatic {
                    _ = await engine.detectLanguage(block.text)
                    guard !Task.isCancelled else { return }
                    // The label can update before token generation and native
                    // styling finish. Its lookup always uses the current text.
                    self?.scheduleCodeToolbarUpdate()
                }
                _ = await engine.analyze(block.text, language: block.language)
                guard !Task.isCancelled, let self,
                      content.blocks.contains(where: { $0.id == block.id && $0.kind == .code && $0.text == block.text && $0.language == block.language }) else { continue }
                // Apply current theme to current source only. IME composition
                // defers this until unmarkText; no characters or history change.
                refreshStyles(force: true, codeBlockID: block.id)
            }
        }
    }

    @objc private func textChanged(_ notification: Notification) {
        guard !applying else { return }
        clearBlockSelection()
        // Deleting the entire editing surface starts a fresh paragraph. A
        // structural conversion or native undo must keep its intentional type.
        if string.isEmpty, !hasMarkedText(), !isRestoringHistory,
           spans.contains(where: { $0.range.length > 0 }) {
            var empty = NoteBlock()
            empty.id = content.blocks.first?.id ?? empty.id
            typingAttributes = BlockTextCodec.style(empty, color: noteColor, theme: codeThemes.theme)
            registerEmptyBlockHistory(before: nil, after: empty)
        }
        // Save the current composition, but do not touch its marked attributes.
        let next = BlockTextCodec.read(attributedString(), typing: typingAttributes)
        let old = content
        spans = next
        content = NoteContent(blocks: next.map(\.block))
        if !hasMarkedText(), !isRestoringHistory, renumberListsIfNeeded() { return }
        if !hasMarkedText() { refreshStyles(previous: old) }
        onContentChange?(content)
        if slashMenu != nil && !slashContextIsValid { dismissSlashMenu() }
    }

    @objc private func selectionChanged(_ notification: Notification) {
        needsDisplay = true
        if !settingBlockSelection && !applying { clearBlockSelection() }
        // The parser catches up in textChanged after a character edit. Pure
        // cursor movement should close suggestions, not modify the document.
        if slashMenu != nil && !slashContextIsValid { dismissSlashMenu() }
        guard !applying, !hasMarkedText(), !isRestoringHistory,
              spans.last.map({ NSMaxRange($0.range) }) == (string as NSString).length else { return }
        updateTypingStyle()
    }

    @objc private func historyChanged(_ notification: Notification) {
        guard let history = notification.object as? UndoManager, history === undoManager else { return }
        clearBlockSelection()
        // AppKit can restore its text storage without calling didChangeText,
        // notably for attribute edits. Publish only after the whole undo group.
        if string.isEmpty, let block = historyEmptyBlock {
            typingAttributes = BlockTextCodec.style(block, color: noteColor, theme: codeThemes.theme)
        }
        historyEmptyBlock = nil
        commitContent()
        synchronizeTableCellEditor(restoringText: true)
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

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let wasBlockSelected = selectedBlockID != nil
        if wasBlockSelected { editSelectedBlock(atEnd: true) }
        if wasBlockSelected, let cell = tableCellEditor {
            cell.setMarkedText(string, selectedRange: selectedRange, replacementRange: cell.selectedRange())
            return
        }
        super.setMarkedText(string, selectedRange: selectedRange,
                            replacementRange: wasBlockSelected ? self.selectedRange() : replacementRange)
    }

    func commitContent() {
        guard !applying else { return }
        spans = BlockTextCodec.read(attributedString(), typing: typingAttributes)
        content = NoteContent(blocks: spans.map(\.block))
        if !hasMarkedText() { refreshStyles(force: true) }
        onContentChange?(content)
        if !slashContextIsValid { dismissSlashMenu() }
    }

    private func refreshStyles(previous: NoteContent? = nil, force: Bool = false, imagesOnly: Bool = false, codeBlockID: UUID? = nil) {
        guard let storage = textStorage, !applying, !hasMarkedText() else { return }
        applying = true
        defer { applying = false }
        let old = Dictionary(uniqueKeysWithValues: (previous ?? content).blocks.map { ($0.id, $0) })
        storage.beginEditing()
        for (index, span) in spans.enumerated() {
            if let codeBlockID, span.block.id != codeBlockID { continue }
            if imagesOnly && !span.block.kind.isAttachment { continue }
            guard force || old[span.block.id] != span.block else { continue }
            if !force, span.block.kind == .code, old[span.block.id]?.kind == .code,
               old[span.block.id]?.language == span.block.language,
               CodeSyntaxEngine.shared.cached(span.block.text, language: span.block.language) == nil {
                // NSTextStorage already shifts existing token attributes with
                // the edit. Keep them while parsing instead of flashing the
                // whole block back to one color on every keystroke.
                scheduleSyntaxHighlighting()
                continue
            }
            let styled = NSMutableAttributedString(attributedString: render(NoteContent(blocks: [span.block]), startingOrdinal: content.listOrdinal(at: index)))
            if index < spans.count - 1 {
                var attrs = BlockTextCodec.style(span.block, color: noteColor, theme: codeThemes.theme)
                attrs[.blockBoundary] = true
                attrs[.nextBlock] = BlockTextCodec.metadata(spans[index + 1].block)
                styled.append(NSAttributedString(string: "\n", attributes: attrs))
            }
            guard NSMaxRange(span.range) <= storage.length,
                  styled.string == (storage.string as NSString).substring(with: span.range) else { continue }
            // Compare against a stable snapshot of the existing runs. Avoid
            // reassigning identical fonts/paragraph metadata during recoloring.
            var updates: [(NSRange, [NSAttributedString.Key: Any])] = []
            styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length)) { attrs, range, _ in
                let target = NSRange(location: span.range.location + range.location, length: range.length)
                storage.enumerateAttributes(in: target) { existing, subrange, _ in
                    if !(existing as NSDictionary).isEqual(to: attrs) { updates.append((subrange, attrs)) }
                }
            }
            for (range, attributes) in updates { storage.setAttributes(attributes, range: range) }
        }
        storage.endEditing()
        synchronizeTableCellEditor()
        updateTypingStyle()
        needsDisplay = true
        scheduleCodeToolbarUpdate()
    }

    private func updateTypingStyle(preservingInlineFormat: Bool = false) {
        guard !hasMarkedText(), let span = activeSpan, let storage = textStorage else { return }
        var attrs = BlockTextCodec.style(span.block, color: noteColor, theme: codeThemes.theme, ordinal: content.listOrdinal(at: activeIndex))
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
            let link = inline[.noteLink] as? String
            let mark = NoteTextMark(location: 0, length: 0, bold: inline[.noteBold] as? Bool ?? false,
                italic: inline[.noteItalic] as? Bool ?? false, code: inline[.noteInlineCode] as? Bool ?? false,
                strikethrough: inline[.noteStrikethrough] as? Bool ?? false, link: link?.isEmpty == false ? link : nil)
            attrs.merge(BlockTextCodec.inlineAttributes(mark, block: span.block, color: noteColor)) { _, new in new }
        }
        // Rebuild from this block, rather than inheriting a previous code
        // line's background, language or separator metadata at its boundary.
        typingAttributes = attrs
        updateCodeCaretColors()
        onBlockKindChange?(span.block.kind)
    }

    private var activeIndex: Int {
        let position = selectedRange().location
        return spans.lastIndex(where: { $0.range.location <= position }) ?? 0
    }
    private var activeSpan: NoteBlockSpan? { spans.indices.contains(activeIndex) ? spans[activeIndex] : nil }

    /// Create a real paragraph only in response to an explicit exit gesture.
    /// Loading a note never adds invisible newlines or changes the saved body.
    @discardableResult
    private func leaveCodeBlock(at index: Int, before: Bool = false) -> Bool {
        guard isEditable, !hasMarkedText(), content.blocks.indices.contains(index),
              content.blocks[index].kind == .code else { return false }
        let adjacent = before ? index - 1 : index + 1
        if spans.indices.contains(adjacent), spans[adjacent].block.kind == .paragraph {
            let range = spans[adjacent].textRange
            setSelectedRange(NSRange(location: before ? NSMaxRange(range) : range.location, length: 0))
            updateTypingStyle()
            scrollRangeToVisible(selectedRange())
        } else {
            let insertion = before ? index : index + 1
            var next = content
            next.blocks.insert(NoteBlock(), at: insertion)
            replaceDocument(next, block: insertion)
        }
        scheduleInsertionPointRefresh()
        return true
    }

    private func leaveCodeAtDocumentBoundary(before: Bool) -> Bool {
        guard !hasMarkedText(), selectedRanges.count == 1, selectedRange().length == 0,
              let span = activeSpan, span.block.kind == .code else { return false }
        let atBoundary = before
            ? activeIndex == 0 && selectedRange().location == span.textRange.location
            : activeIndex == spans.count - 1 && selectedRange().location == NSMaxRange(span.textRange)
        return atBoundary && leaveCodeBlock(at: activeIndex, before: before)
    }

    /// Hit-test only the space outside the first/last code surface. Padding
    /// inside a code block and selection gestures retain normal NSTextView behavior.
    private func leaveCodeFromBlankSpace(at point: NSPoint) -> Bool {
        guard isEditable, !hasMarkedText(), bounds.contains(point), visibleRect.contains(point) else { return false }
        let firstIsCode = spans.first?.block.kind == .code
        let lastIsCode = spans.last?.block.kind == .code
        guard firstIsCode || lastIsCode else { return false }
        let surfaces = codeBlockSurfaces()
        if lastIsCode, let last = spans.last,
           let rect = surfaces.first(where: { $0.blockID == last.block.id })?.rect, point.y > rect.maxY + 2 {
            window?.makeFirstResponder(self)
            return leaveCodeBlock(at: spans.count - 1)
        }
        if firstIsCode, let first = spans.first,
           let rect = surfaces.first(where: { $0.blockID == first.block.id })?.rect, point.y < rect.minY - 2 {
            window?.makeFirstResponder(self)
            return leaveCodeBlock(at: 0, before: true)
        }
        return false
    }

    /// Native insertText records both text and attributes in NSTextView's undo
    /// history. Structural commands join that same history, never a second stack.
    private func replaceDocument(_ next: NoteContent, block index: Int, offset: Int = 0, preservingSelection: Bool = false) {
        guard isEditable, !hasMarkedText() else { NSSound.beep(); return }
        clearBlockSelection()
        dismissSlashMenu()
        breakUndoCoalescing()
        let rendered = render(next)
        let previousSelection = selectedRanges
        let previousScrollOrigin = enclosingScrollView?.contentView.bounds.origin
        let previousEmptyBlock = string.isEmpty ? content.blocks.first : nil
        applying = true
        // Missing optional link/background keys in a rendered run must not
        // inherit the caret's old inline-code or hyperlink attributes.
        typingAttributes = BlockTextCodec.style(NoteBlock(), color: noteColor, theme: codeThemes.theme)
        super.insertText(rendered, replacementRange: NSRange(location: 0, length: (string as NSString).length))
        applying = false
        registerEmptyBlockHistory(before: previousEmptyBlock, after: rendered.length == 0 ? next.blocks.first : nil)
        typingAttributes = BlockTextCodec.style(next.blocks.last ?? NoteBlock(), color: noteColor, theme: codeThemes.theme)
        spans = BlockTextCodec.read(attributedString(), typing: typingAttributes)
        content = NoteContent(blocks: spans.map(\.block))
        if preservingSelection {
            selectedRanges = previousSelection
        } else if spans.indices.contains(index) {
            let span = spans[index]
            setSelectedRange(NSRange(location: span.textRange.location + min(max(0, offset), span.textRange.length), length: 0))
        }
        refreshStyles(force: true)
        onContentChange?(content)
        breakUndoCoalescing()
        if preservingSelection, let previousScrollOrigin {
            enclosingScrollView?.contentView.scroll(to: previousScrollOrigin)
            if let scroll = enclosingScrollView { scroll.reflectScrolledClipView(scroll.contentView) }
        } else if !preservingSelection { scrollRangeToVisible(selectedRange()) }
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
        if selectedBlockID != nil { editSelectedBlock(atEnd: true); return }
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
            typingAttributes = BlockTextCodec.style(span.block, color: noteColor, theme: codeThemes.theme)
            super.insertText(NSAttributedString(string: "\n", attributes: typingAttributes), replacementRange: selectedRange())
            return
        }
        var next = content
        let index = activeIndex
        if span.block.kind == .table {
            beginTableCellEditing(blockID: span.block.id, row: 0, column: 0)
            return
        }
        if span.block.kind.isAttachment {
            next.blocks.insert(NoteBlock(), at: index + 1)
            replaceDocument(next, block: index + 1)
            return
        }
        if span.block.text.isEmpty && (span.block.kind.headingLevel != nil || [.task, .bullet, .orderedList, .quote].contains(span.block.kind)) {
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
        let kind: NoteBlockKind = [.task, .bullet, .orderedList, .quote].contains(span.block.kind) ? span.block.kind : .paragraph
        var following = NoteBlock(kind: kind, text: original.substring(from: end))
        following.marks = clippedMarks(span.block.marks, range: NSRange(location: end, length: original.length - end))
        next.blocks.insert(following, at: index + 1)
        replaceDocument(next, block: index + 1)
    }

    override func insertLineBreak(_ sender: Any?) {
        if selectedBlockID != nil { editSelectedBlock(atEnd: true); return }
        guard isEditable else { return }
        guard !hasMarkedText() else { super.insertLineBreak(sender); return }
        // Code uses ordinary LF characters. Other text blocks use AppKit's
        // native U+2028 line separator, which the codec keeps in the same block.
        if activeSpan?.block.kind == .code || activeSpan?.block.kind.isAttachment == true {
            insertNewline(sender)
            return
        }
        dismissSlashMenu()
        updateTypingStyle(preservingInlineFormat: true)
        super.insertLineBreak(sender)
    }

    private func clippedMarks(_ marks: [NoteTextMark], range: NSRange) -> [NoteTextMark] {
        marks.compactMap { $0.clipped(to: range) }
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let wasBlockSelected = selectedBlockID != nil
        if wasBlockSelected { editSelectedBlock(atEnd: true) }
        if wasBlockSelected, let cell = tableCellEditor {
            cell.insertText(insertString, replacementRange: cell.selectedRange())
            return
        }
        let replacementRange = wasBlockSelected ? selectedRange() : replacementRange
        if !applying, !hasMarkedText(), !isRestoringHistory { updateTypingStyle(preservingInlineFormat: true) }
        let insertedText = (insertString as? String) ?? (insertString as? NSAttributedString)?.string
        let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        let offersSlashMenu = insertedText == "/" && isEditable && !applying && !suppressMarkdownShortcuts &&
            !hasMarkedText() && !isRestoringHistory && range == selectedRange() && range.length == 0
        let shortcut = insertedText == " " ? markdownShortcut(trigger: .space, replacementRange: replacementRange) : nil
        if !applying, !hasMarkedText(), selectedRange().length == 0,
           let span = activeSpan, span.block.kind.isAttachment {
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
        if offersSlashMenu { scheduleSlashMenu() }
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
        if shortcut.kind == .divider {
            next.blocks[index] = NoteBlock(id: blockID, kind: .divider)
            let remainder = text.substring(from: length)
            next.blocks.insert(NoteBlock(text: remainder), at: index + 1)
            replaceDocument(next, block: index + 1)
            return
        }
        next.blocks[index].kind = shortcut.kind
        next.blocks[index].text = text.substring(from: length)
        next.blocks[index].marks = shortcut.kind == .code ? [] : clippedMarks(span.block.marks, range: NSRange(location: length, length: text.length - length))
        next.blocks[index].isChecked = shortcut.isChecked
        next.blocks[index].language = shortcut.language
        replaceDocument(next, block: index)
    }

    override func deleteBackward(_ sender: Any?) {
        if let selectedBlockID { performBlockAction(.delete, blockID: selectedBlockID); return }
        guard !hasMarkedText(), selectedRange().length == 0, let span = activeSpan else { super.deleteBackward(sender); return }
        if span.block.text.isEmpty, selectedRange().location == span.textRange.location,
           (span.block.kind == .code || span.block.kind.headingLevel != nil) {
            changeKind(.paragraph)
            return
        }
        if selectedRange().location == span.textRange.location, [.task, .bullet, .orderedList, .quote].contains(span.block.kind) {
            changeKind(.paragraph)
            return
        }
        if selectedRange().location == span.range.location, activeIndex > 0,
           spans[activeIndex - 1].block.kind.isAttachment {
            setSelectedRange(spans[activeIndex - 1].textRange)
            return
        }
        super.deleteBackward(sender)
    }

    override func mouseDown(with event: NSEvent) {
        clearBlockSelection()
        dismissSlashMenu()
        let point = convert(event.locationInWindow, from: nil)
        if beginTableCellEditing(at: point) { return }
        endTableCellEditing()
        if event.clickCount == 1, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           leaveCodeFromBlankSpace(at: point) { return }
        let position = characterIndexForInsertion(at: point)
        if let span = spans.first(where: { $0.block.kind == .task && position >= $0.range.location && position < $0.textRange.location }) {
            window?.makeFirstResponder(self)
            setSelectedRange(NSRange(location: span.textRange.location, length: 0))
            toggleTask(nil)
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let selectedBlockID, !hasMarkedText() {
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            // Delete always means the selected block, never text in its neighbor.
            if event.keyCode == 51 || event.keyCode == 117 {
                performBlockAction(.delete, blockID: selectedBlockID); return
            }
            if !flags.contains(.command) && !flags.contains(.control) {
                switch event.keyCode {
                case 53: cancelOperation(nil); return
                case 36, 76: editSelectedBlock(atEnd: true); return
                case 123: editSelectedBlock(atEnd: false); return
                case 124: editSelectedBlock(atEnd: true); return
                case 125: moveBlockSelection(1); return
                case 126: moveBlockSelection(-1); return
                default: editSelectedBlock(atEnd: true)
                }
            }
        }
        super.keyDown(with: event)
    }

    override func deleteForward(_ sender: Any?) {
        if let selectedBlockID { performBlockAction(.delete, blockID: selectedBlockID) }
        else { super.deleteForward(sender) }
    }

    override func selectAll(_ sender: Any?) {
        clearBlockSelection()
        super.selectAll(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() { super.cancelOperation(sender) }
        else if slashMenu != nil { dismissSlashMenu() }
        else if selectedBlockID != nil { clearBlockSelection() }
        else { onEscape?() }
    }

    override func moveUp(_ sender: Any?) {
        if selectedBlockID != nil { moveBlockSelection(-1); return }
        if !hasMarkedText(), let slashMenu { slashMenu.moveSelection(-1) }
        else if leaveCodeAtDocumentBoundary(before: true) { return }
        else { super.moveUp(sender) }
    }

    override func moveDown(_ sender: Any?) {
        if selectedBlockID != nil { moveBlockSelection(1); return }
        if !hasMarkedText(), let slashMenu { slashMenu.moveSelection(1) }
        else if leaveCodeAtDocumentBoundary(before: false) { return }
        else { super.moveDown(sender) }
    }

    override func moveLeft(_ sender: Any?) {
        if selectedBlockID != nil { editSelectedBlock(atEnd: false); return }
        if !leaveCodeAtDocumentBoundary(before: true) { super.moveLeft(sender) }
    }

    override func moveRight(_ sender: Any?) {
        if selectedBlockID != nil { editSelectedBlock(atEnd: true); return }
        if !leaveCodeAtDocumentBoundary(before: false) { super.moveRight(sender) }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { scheduleInsertionPointRefresh() }
        return accepted
    }

    @objc private func editorWindowBecameKey(_ notification: Notification) {
        guard let activatedWindow = notification.object as? NSWindow, activatedWindow === window else { return }
        scheduleInsertionPointRefresh()
    }

    @objc private func editorApplicationBecameActive(_ notification: Notification) {
        scheduleInsertionPointRefresh()
    }

    func scheduleInsertionPointRefresh() {
        guard !insertionPointRefreshScheduled else { return }
        insertionPointRefreshScheduled = true
        // A nonactivating panel can retain its first responder while the app
        // activates. Wait until that transition (and expansion layout) settles;
        // makeFirstResponder alone does not restart an existing responder's caret.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.insertionPointRefreshScheduled = false
            guard let window = self.window, window.isKeyWindow, window.isVisible,
                  window.firstResponder === self, self.isEditable,
                  !self.isHiddenOrHasHiddenAncestor, !self.hasMarkedText() else { return }
            self.layoutSubtreeIfNeeded()
            self.needsDisplay = true
            self.updateInsertionPointStateAndRestartTimer(true)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleInsertionPointRefresh()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { dismissSlashMenu() }
        return resigned
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { cancelBlockDrag() }
        if window !== newWindow { dismissSlashMenu(); clearBlockSelection(); codeToolbar?.isHidden = true; blockHandle?.isHidden = true }
        super.viewWillMove(toWindow: newWindow)
    }

    override func scrollWheel(with event: NSEvent) {
        dismissSlashMenu()
        super.scrollWheel(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if let selectedBlockID, !hasMarkedText() {
            if flags == .command {
                switch event.charactersIgnoringModifiers {
                case "c": copy(nil); return true
                case "x": cut(nil); return true
                case "d": performBlockAction(.duplicate, blockID: selectedBlockID); return true
                default: break
                }
            }
            if flags == [.command, .option], event.keyCode == 126 || event.keyCode == 125 {
                performBlockAction(event.keyCode == 126 ? .moveUp : .moveDown, blockID: selectedBlockID)
                return true
            }
            if flags == .command, event.keyCode == 36 || event.keyCode == 76 {
                editSelectedBlock(atEnd: true); return true
            }
        }
        if flags == .shift, event.keyCode == 36 || event.keyCode == 76,
           isEditable, !hasMarkedText() {
            insertLineBreak(nil)
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers == "b" { toggleBold(nil); return true }
        if flags == .command, event.charactersIgnoringModifiers == "i" { toggleItalic(nil); return true }
        if flags == .command, event.keyCode == 36 || event.keyCode == 76, leaveCodeBlock(at: activeIndex) {
            return true
        }
        if flags == [.command, .option], event.keyCode == 126 { moveBlock(-1); return true }
        if flags == [.command, .option], event.keyCode == 125 { moveBlock(1); return true }
        return super.performKeyEquivalent(with: event)
    }

    private var slashContext: SlashCommandContext? {
        guard isEditable, !hasMarkedText(), selectedRange().length == 0, let span = activeSpan,
              let context = SlashCommandContext(block: span.block,
                caretOffset: selectedRange().location - span.textRange.location) else { return nil }
        // Check actual storage as well: selection notifications may arrive
        // before the block parser observes a deletion or composition update.
        let text = string as NSString
        guard NSMaxRange(span.textRange) <= text.length,
              text.substring(with: span.textRange) == span.block.text else { return nil }
        return context
    }

    private var slashContextIsValid: Bool {
        guard let context = slashContext else { return false }
        return slashMenuContext == nil || slashMenuContext == context
    }

    private func scheduleSlashMenu() {
        guard let context = slashContext else { dismissSlashMenu(); return }
        if let window, !window.isKeyWindow { dismissSlashMenu(); return }
        if slashMenuContext != context {
            dismissSlashMenu()
            let blockID = context.source.id
            let entries = NoteBlockKind.allCases.map {
                SlashCommandMenu.Entry(kind: $0, title: $0 == .paragraph ? String(localized: "Text", bundle: bundle) : title($0))
            }
            let suggestions = SlashCommandMenu(blockID: blockID, entries: entries, bundle: bundle)
            suggestions.onChoose = { [weak self] kind in
                guard let self else { return }
                let valid = slashContext == context
                dismissSlashMenu()
                guard valid else { return }
                if kind == .image { chooseImage(nil) } else { changeKind(kind) }
            }
            suggestions.onDismiss = { [weak self] in self?.dismissSlashMenu() }
            slashMenu = suggestions
            slashMenuContext = context
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
        slashMenuContext = nil
    }

    @objc func showBlockMenu(_ sender: Any?) {
        guard isEditable, !hasMarkedText() else { return }
        if let selectedBlockID, let menu = makeBlockActionMenu(blockID: selectedBlockID) {
            let point = blockSurfaces().first(where: { $0.blockID == selectedBlockID })?.rect.origin ?? .zero
            menu.popUp(positioning: nil, at: point, in: self)
            return
        }
        dismissSlashMenu()
        window?.makeFirstResponder(self)
        let rect = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        let point = window.map { convert($0.convertFromScreen(rect).origin, from: nil) } ?? NSPoint(x: 20, y: 20)
        makeBlockMenu().popUp(positioning: nil, at: point, in: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        dismissSlashMenu()
        guard !hasMarkedText(), tableCellEditor?.hasMarkedText() != true else { return nil }
        return contextMenu(at: convert(event.locationInWindow, from: nil)) ?? super.menu(for: event)
    }

    /// Resolve the pointer before consulting selection: another block may
    /// still own the caret or the gutter's previous selection.
    func contextMenu(at point: NSPoint) -> NSMenu? {
        guard isEditable, !hasMarkedText(), tableCellEditor?.hasMarkedText() != true,
              let surface = blockSurfaces().first(where: { $0.rect.contains(point) }),
              let block = content.blocks.first(where: { $0.id == surface.blockID }) else { return nil }
        if block.kind.isAttachment {
            var cell: (row: Int, column: Int)?
            if block.kind == .table, let frame = tableFrame(blockID: block.id) {
                cell = tableLayout(for: block, width: frame.width).cell(at: NSPoint(x: point.x - frame.minX, y: point.y - frame.minY))
            }
            guard selectBlock(block.id) else { return nil }
            return makeBlockActionMenu(blockID: block.id, tableCell: cell)
        }
        endTableCellEditing()
        clearBlockSelection()
        let position = characterIndexForInsertion(at: point)
        let selection = selectedRange()
        if selection.length == 0 || !NSLocationInRange(position, selection) {
            setSelectedRange(NSRange(location: position, length: 0))
        }
        window?.makeFirstResponder(self)
        return makeTextActionMenu(blockID: block.id)
    }

    func makeTextActionMenu(blockID: UUID) -> NSMenu? {
        guard let blockMenu = makeBlockActionMenu(blockID: blockID) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let conversion = blockMenu.items.first(where: { $0.submenu != nil }) {
            blockMenu.removeItem(conversion)
            menu.addItem(conversion)
        }
        if canFormatSelection {
            for (label, selector, key, symbol, mark) in [
                (String(localized: "Bold", bundle: bundle), #selector(toggleBold(_:)), "b", "bold", NSAttributedString.Key.noteBold),
                (String(localized: "Italic", bundle: bundle), #selector(toggleItalic(_:)), "i", "italic", .noteItalic),
                (String(localized: "Strikethrough", bundle: bundle), #selector(toggleStrikethrough(_:)), "", "strikethrough", .noteStrikethrough),
                (String(localized: "Inline Code", bundle: bundle), #selector(toggleInlineCode(_:)), "", "chevron.left.forwardslash.chevron.right", .noteInlineCode)
            ] {
                let item = NSMenuItem(title: label, action: selector, keyEquivalent: key)
                item.target = self
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                item.state = markIsEnabled(mark) ? .on : .off
                menu.addItem(item)
            }
            add(menu, String(localized: "Clear Formatting", bundle: bundle), #selector(clearInlineFormatting(_:)))
            menu.items.last?.image = NSImage(systemSymbolName: "textformat", accessibilityDescription: nil)
        } else if content.blocks.first(where: { $0.id == blockID })?.kind == .code {
            appendCodeActions(to: menu, blockID: blockID)
        }
        menu.addItem(.separator())
        add(menu, String(localized: "Cut", bundle: bundle), #selector(cut(_:)), key: "x", enabled: selectedRange().length > 0)
        add(menu, String(localized: "Copy", bundle: bundle), #selector(copy(_:)), key: "c", enabled: selectedRange().length > 0)
        add(menu, String(localized: "Paste", bundle: bundle), #selector(paste(_:)), key: "v")
        add(menu, String(localized: "Paste as Plain Text", bundle: bundle), #selector(pasteAsPlainText(_:)))
        let actions = NSMenuItem(title: String(localized: "Block actions", bundle: bundle), action: nil, keyEquivalent: "")
        actions.submenu = blockMenu
        menu.addItem(.separator()); menu.addItem(actions)
        return menu
    }

    private func makeBlockMenu() -> NSMenu {
        let menu = NSMenu()
        for kind in NoteBlockKind.allCases where kind != .image {
            let item = NSMenuItem(title: title(kind), action: #selector(selectKind(_:)), keyEquivalent: "")
            item.representedObject = kind.rawValue
            item.target = self
            item.state = activeSpan?.block.kind == kind ? .on : .off
            item.image = BlockMenuIcon.image(for: kind)
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
                let child = NSMenuItem(title: language.title(bundle: bundle),
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
        case .heading3: String(localized: "Heading 3", bundle: bundle)
        case .heading4: String(localized: "Heading 4", bundle: bundle)
        case .bullet: String(localized: "Bullet List", bundle: bundle)
        case .orderedList: String(localized: "Numbered List", bundle: bundle)
        case .divider: String(localized: "Divider", bundle: bundle)
        case .table: String(localized: "Table", bundle: bundle)
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

    func changeKind(_ kind: NoteBlockKind) {
        if let context = slashContext {
            applySlashCommand(NoteBlock(kind: kind), context: context)
            return
        }
        if kind == .divider || kind == .table { insertStructuralBlock(kind); return }
        guard let span = activeSpan else { return }
        var next = content
        var index = activeIndex
        if span.block.kind.isAttachment { index += 1; next.blocks.insert(NoteBlock(), at: index) }
        next.blocks[index].kind = kind
        next.blocks[index].isChecked = false
        if kind == .code {
            next.blocks[index].marks = []
            if span.block.kind != .code { next.blocks[index].language = .automatic }
        }
        replaceDocument(next, block: index, offset: max(0, selectedRange().location - span.textRange.location))
    }

    @discardableResult
    private func applySlashCommand(_ block: NoteBlock, context: SlashCommandContext) -> Bool {
        guard isEditable, !hasMarkedText(), tableCellEditor?.hasMarkedText() != true,
              let insertion = context.inserting(block, in: content) else { return false }
        endTableCellEditing()
        replaceDocument(insertion.content, block: insertion.focusIndex)
        if block.kind == .table {
            beginTableCellEditing(blockID: insertion.content.blocks[insertion.index].id, row: 0, column: 0)
        }
        return true
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let language = CodeLanguage(rawValue: raw),
              let id = activeSpan?.block.id else { return }
        setCodeLanguage(language, blockID: id)
    }

    func setCodeLanguage(_ language: CodeLanguage, blockID: UUID) {
        guard isEditable, !hasMarkedText(),
              let index = content.blocks.firstIndex(where: { $0.id == blockID && $0.kind == .code }),
              content.blocks[index].language != language else { return }
        var next = content
        next.blocks[index].language = language
        replaceDocument(next, block: index, preservingSelection: true)
    }

    @objc private func copyCode(_ sender: Any?) {
        guard let id = activeSpan?.block.id else { return }
        copyCode(blockID: id)
    }

    @discardableResult
    func copyCode(blockID: UUID) -> Bool {
        guard let block = content.blocks.first(where: { $0.id == blockID && $0.kind == .code }) else { return false }
        return writeCodeToPasteboard(block.text)
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
    @objc private func toggleStrikethrough(_ sender: Any?) { toggleMark(.noteStrikethrough) }
    @objc private func toggleInlineCode(_ sender: Any?) { toggleMark(.noteInlineCode) }
    private var canFormatSelection: Bool {
        guard isEditable, !hasMarkedText(), tableCellEditor == nil else { return false }
        let selection = selectedRange()
        let affected = selection.length == 0 ? spans.filter { $0.block.id == activeSpan?.block.id }
            : spans.filter { NSIntersectionRange($0.range, selection).length > 0 }
        return !affected.isEmpty && affected.allSatisfy { !$0.block.kind.isAttachment && $0.block.kind != .code }
    }
    private func markIsEnabled(_ key: NSAttributedString.Key) -> Bool {
        let selection = selectedRange()
        if selection.length == 0 { return typingAttributes[key] as? Bool == true }
        var enabled = true
        attributedString().enumerateAttribute(key, in: selection) { value, _, _ in
            if value as? Bool != true { enabled = false }
        }
        return enabled
    }
    @objc private func clearInlineFormatting(_ sender: Any?) {
        guard canFormatSelection else { return }
        let keys: [NSAttributedString.Key] = [.noteBold, .noteItalic, .noteInlineCode, .noteStrikethrough, .noteLink,
                                             .link, .strikethroughStyle, .underlineStyle, .backgroundColor]
        let selection = selectedRange()
        if selection.length == 0 {
            for key in keys { typingAttributes.removeValue(forKey: key) }
            typingAttributes[.font] = BlockTextCodec.font(activeSpan?.block ?? NoteBlock(), bold: false, italic: false, code: false)
            return
        }
        let value = NSMutableAttributedString(attributedString: attributedString().attributedSubstring(from: selection))
        for key in keys { value.removeAttribute(key, range: NSRange(location: 0, length: value.length)) }
        // Explicit empty marks prevent the insertion caret's old attributes
        // from leaking back into the cleared selection.
        value.addAttributes([.noteBold: false, .noteItalic: false, .noteInlineCode: false, .noteStrikethrough: false, .noteLink: ""],
                            range: NSRange(location: 0, length: value.length))
        breakUndoCoalescing()
        super.insertText(value, replacementRange: selection)
        setSelectedRange(selection)
        refreshStyles(force: true)
        breakUndoCoalescing()
    }
    private func toggleMark(_ key: NSAttributedString.Key) {
        guard canFormatSelection else { return }
        let selection = selectedRange()
        if selection.length == 0 {
            typingAttributes[key] = !(typingAttributes[key] as? Bool ?? false)
            typingAttributes[.font] = BlockTextCodec.font(activeSpan?.block ?? NoteBlock(), bold: typingAttributes[.noteBold] as? Bool ?? false,
                                                          italic: typingAttributes[.noteItalic] as? Bool ?? false,
                                                          code: typingAttributes[.noteInlineCode] as? Bool ?? false)
            return
        }
        let value = NSMutableAttributedString(attributedString: attributedString().attributedSubstring(from: selection))
        let enabled = !markIsEnabled(key)
        value.addAttribute(key, value: enabled, range: NSRange(location: 0, length: value.length))
        breakUndoCoalescing()
        super.insertText(value, replacementRange: selection)
        setSelectedRange(selection)
        refreshStyles(force: true)
        breakUndoCoalescing()
    }

    override func copy(_ sender: Any?) {
        if let selectedBlockID {
            let isImage = content.blocks.first(where: { $0.id == selectedBlockID })?.kind == .image
            performBlockAction(isImage ? .copyImage : .copy, blockID: selectedBlockID)
            return
        }
        super.copy(sender)
        guard selectedRange().length > 0 else { return }
        let value = attributedString().attributedSubstring(from: selectedRange())
        let blocks = BlockTextCodec.read(value, typing: typingAttributes).map(\.block)
        if blocks.contains(where: { $0.kind == .table || $0.kind == .divider }) {
            NSPasteboard.general.setString(NoteContent(blocks: blocks).plainText, forType: .string)
        }
        if let data = try? JSONEncoder().encode(NoteContent(blocks: blocks)) {
            NSPasteboard.general.setData(data, forType: Self.pasteboardType)
        }
    }

    override func cut(_ sender: Any?) {
        guard let selectedBlockID else { super.cut(sender); return }
        if performBlockAction(.copy, blockID: selectedBlockID) {
            performBlockAction(.delete, blockID: selectedBlockID)
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if selectedBlockID != nil, item.action == #selector(copy(_:)) || item.action == #selector(cut(_:)) {
            return isEditable && !hasMarkedText()
        }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        if selectedBlockID != nil { editSelectedBlock(atEnd: true) }
        if let cell = tableCellEditor { cell.paste(sender); return }
        let previous = suppressMarkdownShortcuts
        suppressMarkdownShortcuts = true
        defer { suppressMarkdownShortcuts = previous }
        let board = NSPasteboard.general
        if activeSpan?.block.kind == .code, let text = board.string(forType: .string) {
            insertPastedText(text, interpretingMarkdown: false); return
        }
        if let data = board.data(forType: Self.pasteboardType),
           let value = try? JSONDecoder().decode(NoteContent.self, from: data), (try? value.validate()) != nil {
            if !insertPastedBlocks(value) { insertPastedText(value.plainText, interpretingMarkdown: false) }
            return
        }
        if importImages(from: board) { return }
        if let text = board.string(forType: .string) {
            insertPastedText(text)
        }
    }

    func insertPastedText(_ text: String, interpretingMarkdown: Bool = true) {
        guard isEditable else { return }
        if selectedBlockID != nil { editSelectedBlock(atEnd: true) }
        if let cell = tableCellEditor {
            cell.insertText(text, replacementRange: cell.selectedRange()); return
        }
        let previous = suppressMarkdownShortcuts
        suppressMarkdownShortcuts = true
        defer { suppressMarkdownShortcuts = previous }
        if interpretingMarkdown, !hasMarkedText(), activeSpan?.block.kind != .code,
           let parsed = MarkdownPasteParser.parse(text), insertPastedBlocks(parsed) { return }
        if !hasMarkedText() { updateTypingStyle(preservingInlineFormat: true) }
        // Ordinary text and the explicit plain-text command remain literal.
        insertText(NSAttributedString(string: text, attributes: typingAttributes), replacementRange: selectedRange())
    }

    @discardableResult
    func insertPastedBlocks(_ value: NoteContent) -> Bool {
        guard isEditable, !hasMarkedText(), tableCellEditor == nil, (try? value.validate()) != nil else { return false }
        let range = selectedRange()
        guard range.location != NSNotFound, NSMaxRange(range) <= (string as NSString).length,
              let startIndex = spans.lastIndex(where: { $0.range.location <= range.location }),
              let endIndex = spans.lastIndex(where: { $0.range.location <= NSMaxRange(range) }) else { return false }
        let start = spans[startIndex], end = spans[endIndex]
        // A paste inside code is literal, including a selection that ends in
        // only part of another code block. Whole selected blocks may be replaced.
        guard !(start.block.kind == .code && range.location > start.textRange.location),
              !(end.block.kind == .code && NSMaxRange(range) < NSMaxRange(end.textRange)) else { return false }
        var startOffset = min(start.textRange.length, max(0, range.location - start.textRange.location))
        var endOffset = min(end.textRange.length, max(0, NSMaxRange(range) - end.textRange.location))
        if range.length == 0 && start.block.kind.isAttachment { startOffset = 1; endOffset = 1 }
        guard let insertion = BlockPasteInsertion.inserting(value, into: content,
            from: .init(index: startIndex, offset: startOffset), to: .init(index: endIndex, offset: endOffset)) else { return false }
        replaceDocument(insertion.content, block: insertion.index, offset: insertion.offset)
        undoManager?.setActionName(String(localized: "Paste", bundle: bundle))
        return true
    }

    override func pasteAsPlainText(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        insertPastedText(text, interpretingMarkdown: false)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let previous = suppressMarkdownShortcuts
        suppressMarkdownShortcuts = true
        defer { suppressMarkdownShortcuts = previous }
        return super.readSelection(from: pboard, type: type)
    }

    @objc private func chooseImage(_ sender: Any?) {
        guard !importInProgress, let window, let target = activeSpan?.block.id else { return }
        let command = slashContext
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            self?.importImage(url: url, target: target, command: command)
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
        if sender.draggingPasteboard.types?.contains(BlockReordering.pasteboardType) == true {
            return updateLocalBlockDrag(sender)
        }
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ||
            sender.draggingPasteboard.availableType(from: [.png, .tiff]) != nil { return isEditable ? .copy : [] }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.types?.contains(BlockReordering.pasteboardType) == true {
            return updateLocalBlockDrag(sender)
        }
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if blockDragState != nil { clearBlockDropFeedback() }
        if sender?.draggingPasteboard.types?.contains(BlockReordering.pasteboardType) != true {
            super.draggingExited(sender)
        }
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if sender.draggingPasteboard.types?.contains(BlockReordering.pasteboardType) == true {
            guard matchesLocalBlockDrag(sender) else { return false }
            sender.animatesToDestination = false
            return updateBlockDrop(at: convert(sender.draggingLocation, from: nil)) != nil
        }
        return super.prepareForDragOperation(sender)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        // Keep the source identity until the source session ends; destination
        // cleanup must not invalidate a pending prepare/perform callback.
        if sender.draggingPasteboard.types?.contains(BlockReordering.pasteboardType) == true { clearBlockDropFeedback() }
        else { super.draggingEnded(sender) }
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if sender.draggingPasteboard.types?.contains(BlockReordering.pasteboardType) == true {
            guard matchesLocalBlockDrag(sender) else { return false }
            return finishBlockDrag(at: convert(sender.draggingLocation, from: nil))
        }
        let previous = suppressMarkdownShortcuts
        suppressMarkdownShortcuts = true
        defer { suppressMarkdownShortcuts = previous }
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        setSelectedRange(NSRange(location: index, length: 0))
        return importImages(from: sender.draggingPasteboard) || super.performDragOperation(sender)
    }

    private func importImage(url: URL? = nil, data: Data? = nil, target: UUID, command: SlashCommandContext? = nil) {
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
                if let command {
                    onStatusChange?(applySlashCommand(block, context: command) ? nil : .insertionChanged)
                    return
                }
                let replacesEmpty = next.blocks[index].text.isEmpty && !next.blocks[index].kind.isAttachment
                let destination = replacesEmpty ? index : index + 1
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

extension PaperTextView {
    struct BlockSurface {
        let blockID: UUID
        let rect: NSRect
        let firstLine: NSRect
    }

    func blockSurfaces() -> [BlockSurface] {
        guard let manager = textLayoutManager, let source = manager.textContentManager else { return [] }
        let origin = textContainerOrigin
        let size = textContainer?.size ?? bounds.size
        let padding = textContainer?.lineFragmentPadding ?? 0
        let viewport = manager.textViewportLayoutController.viewportRange
        if let cache = geometryCache, cache.bounds == bounds, cache.visible == visibleRect,
           cache.size == size, cache.origin == origin, cache.padding == padding, cache.viewport == viewport {
            return cache.surfaces
        }
        let surfaces: [BlockSurface] = spans.compactMap { span in
            guard let start = source.location(source.documentRange.location, offsetBy: span.textRange.location),
                  let end = source.location(start, offsetBy: span.textRange.length),
                  let range = NSTextRange(location: start, end: end) else { return nil }
            if let viewport = manager.textViewportLayoutController.viewportRange,
               !viewport.intersects(range), !viewport.contains(start), start.compare(viewport.endLocation) != .orderedSame { return nil }
            var first: NSRect?
            var top = CGFloat.infinity, bottom = -CGFloat.infinity
            manager.enumerateTextSegments(in: range, type: .standard, options: .rangeNotRequired) { _, rect, _, _ in
                if first == nil { first = rect }
                top = min(top, rect.minY); bottom = max(bottom, rect.maxY)
                return true
            }
            guard let first, top.isFinite, bottom.isFinite else { return nil }
            return BlockSurface(blockID: span.block.id,
                rect: NSRect(x: origin.x, y: origin.y + top, width: textContainer?.size.width ?? bounds.width,
                             height: max(20, bottom - top)),
                firstLine: first.offsetBy(dx: origin.x, dy: origin.y))
        }
        geometryCache = (bounds, visibleRect, size, origin, padding, manager.textViewportLayoutController.viewportRange, surfaces)
        // Share one event's geometry between drawing and both hover controls.
        // Never retain it across arbitrary asynchronous TextKit layout passes.
        if !geometryExpiryScheduled {
            geometryExpiryScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.geometryExpiryScheduled = false
                self?.invalidateBlockGeometry()
            }
        }
        return surfaces
    }

    func updateBlockHandle(at point: NSPoint?) {
        guard !updatingBlockHandle, blockHandle?.isPresentingMenu != true,
              blockHandle?.isTrackingPointer != true, blockDragState == nil else { return }
        updatingBlockHandle = true
        defer { updatingBlockHandle = false }
        guard isEditable, !hasMarkedText(), !isHiddenOrHasHiddenAncestor else { blockHandle?.isHidden = true; return }
        let surfaces = blockSurfaces()
        let hovered = point.flatMap { point in
            visibleRect.contains(point) ? surfaces.first { point.y >= $0.rect.minY - 3 && point.y <= $0.rect.maxY + 3 } : nil
        }
        guard let surface = hovered ?? surfaces.first(where: { $0.blockID == selectedBlockID }),
              surface.rect.intersects(visibleRect) else { blockHandle?.isHidden = true; return }
        let handle: BlockHandleButton
        if let existing = blockHandle { handle = existing }
        else {
            handle = BlockHandleButton()
            handle.onOpen = { [weak self] id, button in
                guard let self, selectBlock(id), let menu = makeBlockActionMenu(blockID: id) else { return }
                menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.maxX + 3, y: button.bounds.minY), in: button)
            }
            handle.onMenuFinished = { [weak self] in self?.scheduleBlockHandleUpdate() }
            handle.onPrepareDrag = { [weak self] id in self?.prepareBlockDrag(blockID: id) }
            handle.onDragFinished = { [weak self] in self?.cancelBlockDrag() }
            handle.onPointerChange = { [weak self] point in
                guard let self else { return }
                updateBlockHandle(at: convert(point, from: nil))
            }
            blockHandle = handle
        }
        let container: NSView = enclosingScrollView ?? self
        if handle.superview !== container { handle.removeFromSuperview(); container.addSubview(handle, positioned: .above, relativeTo: nil) }
        handle.blockID = surface.blockID
        handle.ink = noteColor
        handle.updateLanguage(bundle: bundle)
        let y = min(max(surface.firstLine.midY - handle.frame.height / 2, visibleRect.minY + 1), visibleRect.maxY - handle.frame.height - 1)
        let rect = NSRect(x: max(1, textContainerOrigin.x - handle.frame.width - 4), y: y, width: handle.frame.width, height: handle.frame.height)
        guard visibleRect.contains(rect) else { handle.isHidden = true; return }
        let frame = container.backingAlignedRect(container.convert(rect, from: self), options: .alignAllEdgesNearest)
        if handle.frame != frame { handle.frame = frame }
        if handle.isHidden { handle.isHidden = false }
    }

    func scheduleBlockHandleUpdate() {
        guard !blockHandleUpdateScheduled, blockHandle != nil else { return }
        blockHandleUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            blockHandleUpdateScheduled = false
            updateBlockHandle(at: window.map { self.convert($0.mouseLocationOutsideOfEventStream, from: nil) })
        }
    }

    @discardableResult
    func selectBlock(_ id: UUID) -> Bool {
        guard isEditable, !hasMarkedText(), tableCellEditor?.hasMarkedText() != true,
              let span = spans.first(where: { $0.block.id == id }) else { return false }
        endTableCellEditing()
        dismissSlashMenu()
        window?.makeFirstResponder(self)
        settingBlockSelection = true
        setSelectedRange(NSRange(location: span.textRange.location, length: 0))
        settingBlockSelection = false
        selectedBlockID = id
        codeToolbar?.isHidden = true
        needsDisplay = true
        updateInsertionPointStateAndRestartTimer(false)
        scheduleBlockHandleUpdate()
        return true
    }

    func clearBlockSelection() {
        guard selectedBlockID != nil else { return }
        selectedBlockID = nil
        needsDisplay = true
        scheduleInsertionPointRefresh()
        scheduleBlockHandleUpdate()
    }

    private func editSelectedBlock(atEnd: Bool) {
        guard let id = selectedBlockID, let index = spans.firstIndex(where: { $0.block.id == id }) else { clearBlockSelection(); return }
        let span = spans[index]
        clearBlockSelection()
        if span.block.kind == .table {
            beginTableCellEditing(blockID: id, row: 0, column: 0)
            return
        }
        if span.block.kind.isAttachment {
            if !atEnd { setSelectedRange(NSRange(location: span.range.location, length: 0)); return }
            guard isEditable else { return }
            if spans.indices.contains(index + 1), spans[index + 1].block.kind == .paragraph {
                setSelectedRange(NSRange(location: spans[index + 1].textRange.location, length: 0))
            } else {
                var next = content; next.blocks.insert(NoteBlock(), at: index + 1)
                replaceDocument(next, block: index + 1)
            }
        } else {
            setSelectedRange(NSRange(location: atEnd ? NSMaxRange(span.textRange) : span.textRange.location, length: 0))
        }
        updateTypingStyle()
        scheduleInsertionPointRefresh()
    }

    private func moveBlockSelection(_ delta: Int) {
        guard let id = selectedBlockID, let index = spans.firstIndex(where: { $0.block.id == id }), spans.indices.contains(index + delta) else { return }
        let next = spans[index + delta]
        if selectBlock(next.block.id) { scrollRangeToVisible(next.textRange) }
    }

    @objc private func editorWindowResignedKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window, blockHandle?.isPresentingMenu != true else { return }
        clearBlockSelection()
        blockHandle?.isHidden = true
    }

    func makeBlockActionMenu(blockID: UUID, tableCell: (row: Int, column: Int)? = nil) -> NSMenu? {
        guard isEditable, !hasMarkedText(), tableCellEditor?.hasMarkedText() != true,
              let index = content.blocks.firstIndex(where: { $0.id == blockID }) else { return nil }
        let block = content.blocks[index]
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: title(block.kind), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        func item(_ label: String, _ action: BlockAction, symbol: String? = nil, key: String = "", enabled: Bool = true) -> NSMenuItem {
            let result = NSMenuItem(title: label, action: #selector(performBlockMenuAction(_:)), keyEquivalent: key)
            result.target = self
            result.representedObject = BlockMenuCommand(blockID: blockID, action: action)
            result.isEnabled = enabled
            if let symbol { result.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            return result
        }
        let convert = NSMenuItem(title: String(localized: "Turn into", bundle: bundle), action: nil, keyEquivalent: "")
        convert.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        let kinds = NSMenu()
        kinds.autoenablesItems = false
        for kind in NoteBlockKind.allCases where !kind.isAttachment {
            let child = item(title(kind), .convert(kind), enabled: !block.kind.isAttachment)
            child.image = BlockMenuIcon.image(for: kind)
            child.state = block.kind == kind ? .on : .off
            kinds.addItem(child)
        }
        convert.submenu = kinds
        convert.isEnabled = !block.kind.isAttachment
        if !block.kind.isAttachment { menu.addItem(convert) }
        if block.kind == .code {
            menu.addItem(.separator())
            appendCodeActions(to: menu, blockID: blockID)
        }
        if block.kind == .task {
            let completed = item(String(localized: "Toggle Completed", bundle: bundle), .toggleTask, symbol: "checkmark.square")
            completed.state = block.isChecked ? .on : .off
            menu.addItem(completed)
        }
        if block.kind == .table {
            menu.addItem(.separator())
            menu.addItem(item(String(localized: "Add Row", bundle: bundle), .addTableRow, symbol: "plus"))
            menu.addItem(item(String(localized: "Add Column", bundle: bundle), .addTableColumn, symbol: "plus"))
            let headerRow = item(String(localized: "Header Row", bundle: bundle), .toggleHeaderRow, symbol: "rectangle.split.1x2")
            headerRow.state = block.table?.headerRow == true ? .on : .off
            menu.addItem(headerRow)
            let headerColumn = item(String(localized: "Header Column", bundle: bundle), .toggleHeaderColumn, symbol: "rectangle.split.2x1")
            headerColumn.state = block.table?.headerColumn == true ? .on : .off
            menu.addItem(headerColumn)
            if let cell = tableCell, let table = block.table,
               table.rows.indices.contains(cell.row), (0..<table.columnCount).contains(cell.column) {
                menu.addItem(.separator())
                menu.addItem(item(String(localized: "Insert Row Above", bundle: bundle), .insertTableRow(cell.row), symbol: "arrow.up"))
                menu.addItem(item(String(localized: "Insert Row Below", bundle: bundle), .insertTableRow(cell.row + 1), symbol: "arrow.down"))
                menu.addItem(item(String(localized: "Insert Column Left", bundle: bundle), .insertTableColumn(cell.column), symbol: "arrow.left"))
                menu.addItem(item(String(localized: "Insert Column Right", bundle: bundle), .insertTableColumn(cell.column + 1), symbol: "arrow.right"))
                menu.addItem(item(String(localized: "Delete Row", bundle: bundle), .deleteTableRow(cell.row), symbol: "minus", enabled: table.rows.count > 1))
                menu.addItem(item(String(localized: "Delete Column", bundle: bundle), .deleteTableColumn(cell.column), symbol: "minus", enabled: table.columnCount > 1))
            }
        }
        menu.addItem(.separator())
        if block.kind == .image {
            menu.addItem(item(String(localized: "Copy Image", bundle: bundle), .copyImage, symbol: "photo.on.rectangle", key: "c"))
        }
        menu.addItem(item(String(localized: "Copy Block", bundle: bundle), .copy, symbol: "doc.on.clipboard", key: block.kind == .image ? "" : "c"))
        menu.addItem(item(String(localized: "Duplicate Block", bundle: bundle), .duplicate, symbol: "doc.on.doc", key: "d"))
        let up = item(String(localized: "Move Block Up", bundle: bundle), .moveUp, symbol: "arrow.up", enabled: index > 0)
        let down = item(String(localized: "Move Block Down", bundle: bundle), .moveDown, symbol: "arrow.down", enabled: index < content.blocks.count - 1)
        menu.addItem(up); menu.addItem(down)
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Delete Block", bundle: bundle), .delete, symbol: "trash"))
        return menu
    }

    private func appendCodeActions(to menu: NSMenu, blockID: UUID) {
        guard let block = content.blocks.first(where: { $0.id == blockID && $0.kind == .code }) else { return }
        let language = NSMenuItem(title: String(localized: "Code Language", bundle: bundle), action: nil, keyEquivalent: "")
        language.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)
        let choices = NSMenu(); choices.autoenablesItems = false
        for value in CodeLanguage.allCases {
            let item = NSMenuItem(title: value.title(bundle: bundle), action: #selector(performBlockMenuAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = BlockMenuCommand(blockID: blockID, action: .codeLanguage(value))
            item.state = block.language == value ? .on : .off
            choices.addItem(item)
        }
        language.submenu = choices; menu.addItem(language)
        let copy = NSMenuItem(title: String(localized: "Copy Code", bundle: bundle), action: #selector(performBlockMenuAction(_:)), keyEquivalent: "")
        copy.target = self; copy.representedObject = BlockMenuCommand(blockID: blockID, action: .copyCode)
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        menu.addItem(copy)
    }

    @objc private func performBlockMenuAction(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? BlockMenuCommand else { return }
        if command.action == .addTableRow || command.action == .addTableColumn {
            addTableDimension(blockID: command.blockID, addingRow: command.action == .addTableRow)
        } else { performBlockAction(command.action, blockID: command.blockID) }
    }

    @discardableResult
    func performBlockAction(_ action: BlockAction, blockID: UUID) -> Bool {
        guard isEditable, !hasMarkedText(), tableCellEditor?.hasMarkedText() != true,
              let index = content.blocks.firstIndex(where: { $0.id == blockID }) else { return false }
        var next = content
        var destination = index
        var selectedID: UUID? = blockID
        switch action {
        case .copyCode: return copyCode(blockID: blockID)
        case .codeLanguage(let language):
            guard content.blocks[index].kind == .code else { return false }
            setCodeLanguage(language, blockID: blockID)
            return true
        case .toggleTask:
            guard next.blocks[index].kind == .task else { return false }
            next.blocks[index].isChecked.toggle()
        case .copyImage:
            guard content.blocks[index].kind == .image, let image = content.blocks[index].image else { return false }
            guard let file else { onStatusChange?(.imageCopyFailed); return false }
            do {
                try writeImageToPasteboard(image, file)
                onStatusChange?(nil)
                return true
            } catch {
                onStatusChange?(.imageCopyFailed)
                return false
            }
        case .copy:
            return writeBlockToPasteboard(NoteContent(blocks: [content.blocks[index]]))
        case .convert(let kind):
            guard !kind.isAttachment, !next.blocks[index].kind.isAttachment else { return false }
            if next.blocks[index].kind == kind { return selectBlock(blockID) }
            next.blocks[index].kind = kind
            next.blocks[index].isChecked = false
            if kind == .code { next.blocks[index].marks = []; next.blocks[index].language = .automatic }
        case .duplicate:
            var copy = next.blocks[index]; copy.id = UUID()
            destination += 1; selectedID = copy.id
            next.blocks.insert(copy, at: destination)
        case .addTableRow, .addTableColumn:
            guard var table = next.blocks[index].table else { return false }
            if action == .addTableRow {
                table.rows.append(Array(repeating: "", count: table.columnCount))
            } else {
                for row in table.rows.indices { table.rows[row].append("") }
            }
            next.blocks[index].table = table
        case .toggleHeaderRow, .toggleHeaderColumn:
            guard var table = next.blocks[index].table else { return false }
            if action == .toggleHeaderRow { table.headerRow.toggle() }
            else { table.headerColumn.toggle() }
            next.blocks[index].table = table
        case .insertTableRow(let row):
            guard var table = next.blocks[index].table, (0...table.rows.count).contains(row) else { return false }
            table.rows.insert(Array(repeating: "", count: table.columnCount), at: row)
            next.blocks[index].table = table
        case .insertTableColumn(let column):
            guard var table = next.blocks[index].table, (0...table.columnCount).contains(column) else { return false }
            for row in table.rows.indices { table.rows[row].insert("", at: column) }
            next.blocks[index].table = table
        case .deleteTableRow(let row):
            guard var table = next.blocks[index].table, table.rows.count > 1, table.rows.indices.contains(row) else { return false }
            table.rows.remove(at: row)
            next.blocks[index].table = table
        case .deleteTableColumn(let column):
            guard var table = next.blocks[index].table, table.columnCount > 1, (0..<table.columnCount).contains(column) else { return false }
            for row in table.rows.indices { table.rows[row].remove(at: column) }
            next.blocks[index].table = table
        case .moveUp, .moveDown:
            destination += action == .moveUp ? -1 : 1
            guard next.blocks.indices.contains(destination) else { return false }
            next.blocks.swapAt(index, destination)
        case .delete:
            next.blocks.remove(at: index)
            if next.blocks.isEmpty { next.blocks = [NoteBlock()] }
            destination = min(index, next.blocks.count - 1)
            selectedID = nil
        }
        replaceDocument(next, block: destination)
        switch action {
        case .insertTableRow(let row): beginTableCellEditing(blockID: blockID, row: row, column: 0); return true
        case .insertTableColumn(let column): beginTableCellEditing(blockID: blockID, row: 0, column: column); return true
        default: break
        }
        if let selectedID { selectBlock(selectedID) }
        return true
    }
}

// MARK: - Dragging entire blocks
extension PaperTextView {
    func prepareBlockDrag(blockID: UUID) -> BlockDragPreview? {
        guard blockDragState == nil, isEditable, !hasMarkedText(), tableCellEditor?.hasMarkedText() != true,
              let block = content.blocks.first(where: { $0.id == blockID }), selectBlock(blockID) else { return nil }
        let state = BlockDragState(blockID: blockID, originalOrder: content.blocks.map(\.id))
        blockDragState = state
        blockHandle?.alphaValue = 0.45
        let text = block.plainText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let label = text.trimmingCharacters(in: .whitespaces).isEmpty ? title(block.kind) : String(text.prefix(80))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let caption = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ])
        let image = NSImage(size: NSSize(width: min(250, max(110, caption.size().width + 44)), height: 36), flipped: true) { rect in
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            NSColor.controlBackgroundColor.setFill(); shape.fill()
            NSColor.separatorColor.setStroke(); shape.lineWidth = 1; shape.stroke()
            BlockMenuIcon.image(for: block.kind)?.draw(in: NSRect(x: 9, y: 9, width: 18, height: 18))
            caption.draw(in: NSRect(x: 34, y: (rect.height - caption.size().height) / 2,
                                   width: rect.width - 44, height: caption.size().height))
            return true
        }
        return BlockDragPreview(token: state.token, image: image)
    }

    private var blockDragIsValid: Bool {
        guard let state = blockDragState else { return false }
        return isEditable && !hasMarkedText() && tableCellEditor?.hasMarkedText() != true &&
            !isHiddenOrHasHiddenAncestor && content.blocks.count == state.originalOrder.count &&
            zip(content.blocks, state.originalOrder).allSatisfy { $0.id == $1 }
    }

    private func matchesLocalBlockDrag(_ sender: any NSDraggingInfo) -> Bool {
        guard blockDragIsValid, let handle = blockHandle, sender.draggingSource as? BlockHandleButton === handle,
              let token = sender.draggingPasteboard.string(forType: BlockReordering.pasteboardType) else { return false }
        return token == blockDragState?.token.uuidString
    }

    /// Read layout and preview a gap; never mutate text during pointer movement.
    @discardableResult
    func updateBlockDrop(at point: NSPoint) -> BlockDropTarget? {
        if let previous = blockDropTarget { setNeedsDisplay(previous.indicator.insetBy(dx: -4, dy: -4)) }
        blockDropTarget = nil
        guard blockDragIsValid, let state = blockDragState, visibleRect.contains(point) else { return nil }
        let surfaces = blockSurfaces()
        guard let last = surfaces.last else { return nil }
        let beforeID: UUID?
        let y: CGFloat
        if let position = surfaces.firstIndex(where: { point.y < $0.rect.midY }) {
            let surface = surfaces[position]
            beforeID = surface.blockID
            y = position > 0 ? (surfaces[position - 1].rect.maxY + surface.rect.minY) / 2 : surface.rect.minY - 4
        } else {
            guard let index = content.blocks.firstIndex(where: { $0.id == last.blockID }) else { return nil }
            beforeID = index + 1 < content.blocks.count ? content.blocks[index + 1].id : nil
            y = last.rect.maxY + 4
        }
        guard BlockReordering.destinationIndex(of: state.blockID, before: beforeID, in: content) != nil else { return nil }
        let width = max(20, (textContainer?.size.width ?? bounds.width - textContainerInset.width * 2) - 2)
        let rect = backingAlignedRect(NSRect(x: textContainerOrigin.x, y: min(max(y, visibleRect.minY + 3), visibleRect.maxY - 4),
                                            width: width, height: 2), options: .alignAllEdgesNearest)
        let target = BlockDropTarget(beforeBlockID: beforeID, indicator: rect)
        blockDropTarget = target
        setNeedsDisplay(rect.insetBy(dx: -4, dy: -4))
        return target
    }

    private func updateLocalBlockDrag(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard matchesLocalBlockDrag(sender) else { clearBlockDropFeedback(); return [] }
        blockDragLocationInWindow = sender.draggingLocation
        let point = convert(sender.draggingLocation, from: nil)
        let target = updateBlockDrop(at: point)
        let scrolling = BlockReordering.scrollStep(at: point, in: visibleRect) != 0 && enclosingScrollView != nil
        if scrolling && blockDragScrollTimer == nil {
            let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] timer in
                let shouldStop = MainActor.assumeIsolated {
                    guard let self, let point = self.blockDragLocationInWindow, self.window != nil, self.blockDragIsValid else {
                        self?.clearBlockDropFeedback(); return true
                    }
                    _ = self.scrollBlockDrag(at: self.convert(point, from: nil))
                    _ = self.updateBlockDrop(at: self.convert(point, from: nil))
                    return false
                }
                if shouldStop { timer.invalidate() }
            }
            blockDragScrollTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
        } else if !scrolling {
            blockDragScrollTimer?.invalidate(); blockDragScrollTimer = nil
        }
        // Accept edge hovering even before the next gap is visible, so native
        // drag tracking continues while the document scrolls underneath it.
        return target != nil || scrolling ? .move : []
    }

    @discardableResult
    func scrollBlockDrag(at point: NSPoint) -> Bool {
        guard blockDragIsValid, let scroll = enclosingScrollView else { return false }
        let step = BlockReordering.scrollStep(at: point, in: visibleRect)
        guard step != 0 else { return false }
        let clip = scroll.contentView
        let maxY = max(0, bounds.maxY - clip.bounds.height)
        let destination = min(max(clip.bounds.minY + step, 0), maxY)
        guard destination != clip.bounds.minY else { return false }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: destination))
        scroll.reflectScrolledClipView(clip)
        textLayoutManager?.textViewportLayoutController.layoutViewport()
        return true
    }

    @discardableResult
    func finishBlockDrag(at point: NSPoint) -> Bool {
        guard blockDragIsValid, let state = blockDragState, let target = updateBlockDrop(at: point),
              let moved = BlockReordering.moving(state.blockID, before: target.beforeBlockID, in: content) else {
            cancelBlockDrag(); return false
        }
        cancelBlockDrag()
        let history = undoManager
        history?.beginUndoGrouping()
        replaceDocument(moved.content, block: moved.index)
        history?.setActionName(String(localized: "Move Block", bundle: bundle))
        history?.endUndoGrouping()
        selectBlock(state.blockID)
        return true
    }

    private func clearBlockDropFeedback() {
        if let target = blockDropTarget { setNeedsDisplay(target.indicator.insetBy(dx: -4, dy: -4)) }
        blockDropTarget = nil
        blockDragLocationInWindow = nil
        blockDragScrollTimer?.invalidate()
        blockDragScrollTimer = nil
    }

    func cancelBlockDrag() {
        clearBlockDropFeedback()
        blockDragState = nil
        blockHandle?.alphaValue = 1
        scheduleBlockHandleUpdate()
    }
}

// MARK: - Numbered lists and native table cells
extension PaperTextView {
    private func tableLayout(for block: NoteBlock, width: CGFloat) -> TableBlockLayout {
        let table = block.table ?? NoteTable()
        let previous = tableLayouts[block.id]
        if let previous, previous.table == table, previous.width == max(80, width) { return previous }
        let layout = TableBlockLayout(table: table, width: width, reusing: previous)
        // At most one current snapshot per table, with a bounded editor cache.
        if tableLayouts.count >= 16, previous == nil { tableLayouts.removeAll() }
        tableLayouts[block.id] = layout
        return layout
    }

    private func renumberListsIfNeeded() -> Bool {
        let source = string as NSString
        let mismatch = spans.enumerated().contains { index, span in
            guard span.block.kind == .orderedList else { return false }
            let markerRange = NSRange(location: span.range.location, length: span.textRange.location - span.range.location)
            return source.substring(with: markerRange) != BlockTextCodec.prefix(span.block, ordinal: content.listOrdinal(at: index))
        }
        guard mismatch, let active = activeSpan else { return false }
        let offset = max(0, selectedRange().location - active.textRange.location)
        replaceDocument(content, block: activeIndex, offset: offset)
        return true
    }

    private func insertStructuralBlock(_ kind: NoteBlockKind) {
        guard isEditable, !hasMarkedText(), tableCellEditor?.hasMarkedText() != true, let span = activeSpan else { return }
        endTableCellEditing()
        var next = content
        var index = activeIndex
        let empty = !span.block.kind.isAttachment && span.block.text.isEmpty
        let block = NoteBlock(id: empty ? span.block.id : UUID(), kind: kind)
        if empty { next.blocks[index] = block }
        else { index += 1; next.blocks.insert(block, at: index) }
        if index == next.blocks.count - 1 { next.blocks.append(NoteBlock()) }
        replaceDocument(next, block: kind == .table ? index : index + 1)
        if kind == .table { beginTableCellEditing(blockID: block.id, row: 0, column: 0) }
    }

    func tableFrame(blockID: UUID) -> NSRect? {
        guard let span = spans.first(where: { $0.block.id == blockID }), span.block.table != nil,
              blockSurfaces().contains(where: { $0.blockID == blockID }),
              let manager = textLayoutManager, let source = manager.textContentManager,
              let location = source.location(source.documentRange.location, offsetBy: span.textRange.location),
              let fragment = manager.textLayoutFragment(for: location) else { return nil }
        // Standard text segments include baseline / paragraph leading, so their
        // top edge is not the attachment's top. Use TextKit's actual image frame.
        let attachment = fragment.frameForTextAttachment(at: location)
        guard attachment.width > 0, attachment.height > 0 else { return nil }
        let layout = tableLayout(for: span.block, width: attachment.width)
        let origin = NSPoint(x: textContainerOrigin.x + fragment.layoutFragmentFrame.minX + attachment.minX,
                             y: textContainerOrigin.y + fragment.layoutFragmentFrame.minY + attachment.minY)
        return NSRect(origin: origin, size: layout.size)
    }

    func updateTableControls(at point: NSPoint?) {
        guard !isHiddenOrHasHiddenAncestor, blockDragState == nil, enclosingScrollView != nil else {
            tableControls?.isHidden = true; return
        }
        let hovered = point.flatMap { point in
            content.blocks.first { block in
                guard block.table != nil, let grid = tableFrame(blockID: block.id) else { return false }
                return visibleRect.contains(point) && NSRect(x: grid.minX, y: grid.minY,
                    width: grid.width + 24, height: grid.height + TableBlockLayout.controlsHeight).contains(point)
            }?.id
        }
        let controlID: UUID? = tableControls.flatMap { controls in
            guard let point, controls.containsControl(at: controls.convert(point, from: self)) else { return nil }
            return controls.blockID
        }
        guard let id = hovered ?? controlID ?? editingTableCell?.id ?? selectedBlockID,
              let grid = tableFrame(blockID: id), grid.intersects(visibleRect) else {
            tableControls?.isHidden = true; return
        }
        let controls: TableAddControls
        if let existing = tableControls { controls = existing }
        else {
            controls = TableAddControls()
            controls.onAdd = { [weak self] id, row in self?.addTableDimension(blockID: id, addingRow: row) }
            controls.onPointerChange = { [weak self] point in
                guard let self else { return }
                updateTableControls(at: convert(point, from: nil))
            }
            tableControls = controls
        }
        let container = enclosingScrollView!
        if controls.superview !== container {
            controls.removeFromSuperview()
            controls.frame = container.bounds
            container.addSubview(controls, positioned: .above, relativeTo: nil)
        }
        controls.blockID = id
        controls.updateColors(noteColor)
        controls.update(grid: grid, viewport: visibleRect, editor: self, bundle: bundle,
                        enabled: isEditable && !hasMarkedText() && tableCellEditor?.hasMarkedText() != true)
    }

    private func scheduleTableControlsUpdate() {
        guard !tableControlsUpdateScheduled, tableControls != nil || editingTableCell != nil else { return }
        tableControlsUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            tableControlsUpdateScheduled = false
            synchronizeTableCellEditor()
            updateTableControls(at: window.map { self.convert($0.mouseLocationOutsideOfEventStream, from: nil) })
        }
    }

    @discardableResult
    func addTableDimension(blockID: UUID, addingRow: Bool) -> Bool {
        guard performBlockAction(addingRow ? .addTableRow : .addTableColumn, blockID: blockID),
              let table = content.blocks.first(where: { $0.id == blockID })?.table else { return false }
        beginTableCellEditing(blockID: blockID, row: addingRow ? table.rows.count - 1 : 0,
                              column: addingRow ? 0 : table.columnCount - 1)
        if let cell = tableCellEditor { scrollToVisible(cell.frame) }
        scheduleTableControlsUpdate()
        return true
    }

    private func beginTableCellEditing(at point: NSPoint) -> Bool {
        for block in content.blocks where block.kind == .table {
            guard block.table != nil, let frame = tableFrame(blockID: block.id), frame.contains(point) else { continue }
            let layout = tableLayout(for: block, width: frame.width)
            if let cell = layout.cell(at: NSPoint(x: point.x - frame.minX, y: point.y - frame.minY)) {
                beginTableCellEditing(blockID: block.id, row: cell.row, column: cell.column)
                if let editor = tableCellEditor {
                    let local = editor.convert(point, from: self)
                    editor.setSelectedRange(NSRange(location: editor.characterIndexForInsertion(at: local), length: 0))
                }
                return true
            }
        }
        return false
    }

    func beginTableCellEditing(blockID: UUID, row: Int, column: Int) {
        guard isEditable, !hasMarkedText(), tableCellEditor?.hasMarkedText() != true,
              let span = spans.first(where: { $0.block.id == blockID }), let table = span.block.table,
              table.rows.indices.contains(row), table.rows[row].indices.contains(column) else { return }
        endTableCellEditing()
        clearBlockSelection()
        dismissSlashMenu()
        setSelectedRange(NSRange(location: span.range.location, length: 0))
        scrollRangeToVisible(span.textRange)
        if let manager = textLayoutManager, let source = manager.textContentManager,
           let start = source.location(source.documentRange.location, offsetBy: span.textRange.location),
           let end = source.location(start, offsetBy: span.textRange.length),
           let range = NSTextRange(location: start, end: end) { manager.ensureLayout(for: range) }
        editingTableCell = (blockID, row, column)
        let cell = TableCellTextView(usingTextLayoutManager: true)
        cell.isRichText = false
        cell.allowsUndo = false
        cell.hostUndoManager = undoManager
        cell.font = table.isHeader(row: row, column: column) ? TableBlockLayout.headerFont : TableBlockLayout.font
        cell.textColor = noteColor
        cell.drawsBackground = true
        cell.backgroundColor = noteColor == NotePalette.paperText ? paperBackground : .textBackgroundColor
        cell.insertionPointColor = noteColor
        cell.usesAdaptiveColorMappingForDarkAppearance = false
        cell.isAutomaticQuoteSubstitutionEnabled = false
        cell.isAutomaticDashSubstitutionEnabled = false
        cell.isVerticallyResizable = false
        cell.isHorizontallyResizable = false
        cell.textContainerInset = NSSize(width: TableBlockLayout.padding, height: TableBlockLayout.padding)
        cell.textContainer?.lineFragmentPadding = 0
        cell.textContainer?.widthTracksTextView = true
        cell.string = table.rows[row][column]
        cell.setAccessibilityLabel(String(localized: "Table cell", bundle: bundle) + " \(row + 1), \(column + 1)")
        cell.setAccessibilityHelp(String(localized: "Tab: next cell. Shift-Tab: previous cell. Command-Return: leave table.", bundle: bundle))
        cell.onTextChange = { [weak self] text in self?.updateTableCell(blockID: blockID, row: row, column: column, text: text) }
        cell.onNavigate = { [weak self] delta in self?.navigateTableCell(delta) }
        cell.onExit = { [weak self] in self?.leaveTable() }
        cell.onContextMenu = { [weak self] in
            self?.makeBlockActionMenu(blockID: blockID, tableCell: (row, column))
        }
        cell.onHistory = { [weak self] redo in
            guard let self else { return }
            if redo { undoManager?.redo() } else { undoManager?.undo() }
        }
        tableCellEditor = cell
        addSubview(cell)
        synchronizeTableCellEditor()
        cell.setSelectedRange(NSRange(location: (cell.string as NSString).length, length: 0))
        window?.makeFirstResponder(cell)
        scheduleTableControlsUpdate()
    }

    func updateTableCell(blockID: UUID, row: Int, column: Int, text: String) {
        guard isEditable, !updatingTableCell, let index = spans.firstIndex(where: { $0.block.id == blockID }),
              var table = spans[index].block.table, table.rows.indices.contains(row), table.rows[row].indices.contains(column),
              table.rows[row][column] != text else { return }
        table.rows[row][column] = text
        var block = spans[index].block
        block.table = table
        let previousSelection = selectedRanges
        // Replacing one immutable attachment snapshot enters the host's native
        // undo stack. The active cell stays alive, including its IME selection.
        applying = true
        super.insertText(render(NoteContent(blocks: [block])), replacementRange: spans[index].textRange)
        // An attachment remains exactly one UTF-16 unit. All other ranges and
        // their native attributes are unchanged, so no whole-note read/restyle.
        spans[index].block = block
        content.blocks[index] = block
        if index > 0 {
            let separator = NSRange(location: spans[index].range.location - 1, length: 1)
            textStorage?.addAttribute(.nextBlock, value: BlockTextCodec.metadata(block), range: separator)
        }
        applying = false
        selectedRanges = previousSelection
        synchronizeTableCellEditor()
        updateTypingStyle()
        needsDisplay = true
        scheduleCodeToolbarUpdate()
        onContentChange?(content)
    }

    private func synchronizeTableCellEditor(restoringText: Bool = false) {
        guard !updatingTableCell, let editing = editingTableCell, let cell = tableCellEditor else { return }
        guard let block = content.blocks.first(where: { $0.id == editing.id }), let table = block.table,
              table.rows.indices.contains(editing.row), table.rows[editing.row].indices.contains(editing.column) else {
            endTableCellEditing(); return
        }
        updatingTableCell = true
        defer { updatingTableCell = false }
        if restoringText, !cell.hasMarkedText(), cell.string != table.rows[editing.row][editing.column] {
            let caret = cell.selectedRange().location
            cell.string = table.rows[editing.row][editing.column]
            cell.setSelectedRange(NSRange(location: min(caret, (cell.string as NSString).length), length: 0))
        }
        if cell.textColor != noteColor { cell.textColor = noteColor }
        if cell.insertionPointColor != noteColor { cell.insertionPointColor = noteColor }
        let background = noteColor == NotePalette.paperText ? paperBackground : NSColor.textBackgroundColor
        if cell.backgroundColor != background { cell.backgroundColor = background }
        let font = table.isHeader(row: editing.row, column: editing.column) ? TableBlockLayout.headerFont : TableBlockLayout.font
        if cell.font != font { cell.font = font }
        if let frame = tableFrame(blockID: editing.id) {
            let layout = tableLayout(for: block, width: frame.width)
            let rect = layout.rect(row: editing.row, column: editing.column).offsetBy(dx: frame.minX, dy: frame.minY)
            if cell.frame != rect { cell.frame = rect }
            let size = NSSize(width: max(12, rect.width - TableBlockLayout.padding * 2), height: .greatestFiniteMagnitude)
            if cell.textContainer?.containerSize != size { cell.textContainer?.containerSize = size }
        }
    }

    private func navigateTableCell(_ delta: Int) {
        guard let editing = editingTableCell, let index = content.blocks.firstIndex(where: { $0.id == editing.id }),
              let table = content.blocks[index].table, tableCellEditor?.hasMarkedText() != true else { return }
        let position = editing.row * table.columnCount + editing.column + delta
        if position < 0 { endTableCellEditing(); window?.makeFirstResponder(self); return }
        if position >= table.rows.count * table.columnCount {
            var next = content
            next.blocks[index].table?.rows.append(Array(repeating: "", count: table.columnCount))
            replaceDocument(next, block: index)
        }
        beginTableCellEditing(blockID: editing.id, row: position / table.columnCount, column: position % table.columnCount)
    }

    private func leaveTable() {
        guard let id = editingTableCell?.id, let index = content.blocks.firstIndex(where: { $0.id == id }),
              tableCellEditor?.hasMarkedText() != true else { return }
        endTableCellEditing()
        window?.makeFirstResponder(self)
        if content.blocks.indices.contains(index + 1), !content.blocks[index + 1].kind.isAttachment {
            setSelectedRange(NSRange(location: spans[index + 1].textRange.location, length: 0))
        } else {
            var next = content
            next.blocks.insert(NoteBlock(), at: index + 1)
            replaceDocument(next, block: index + 1)
        }
        scrollRangeToVisible(selectedRange())
    }

    private func endTableCellEditing() {
        if let cell = tableCellEditor, window?.firstResponder === cell { window?.makeFirstResponder(self) }
        tableCellEditor?.removeFromSuperview()
        tableCellEditor = nil
        editingTableCell = nil
        scheduleTableControlsUpdate()
    }
}
