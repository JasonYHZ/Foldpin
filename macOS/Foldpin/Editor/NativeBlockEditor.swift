import AppKit
import UniformTypeIdentifiers
import AVFoundation
import Combine

enum NoteEditorStatus: Equatable {
    case importingAttachment, importingImage, insertionChanged, imageFailed, imageCopyFailed

    func description(bundle: Bundle) -> String {
        switch self {
        case .importingAttachment: String(localized: "Importing attachments…", bundle: bundle)
        case .importingImage: String(localized: "Importing image…", bundle: bundle)
        case .insertionChanged: String(localized: "The insertion block changed. Please insert the image again.", bundle: bundle)
        case .imageFailed: String(localized: "Could not insert image. Choose an image under 40 MB and 80 megapixels.", bundle: bundle)
        case .imageCopyFailed: String(localized: "Could not copy image. Check that its image file is available and try again.", bundle: bundle)
        }
    }
}

final class PaperTextView: NSTextView {
    var sessionUndoManager: UndoManager?
    override var undoManager: UndoManager? { sessionUndoManager ?? super.undoManager }

    func commitForHandoff() {
        if let responder = window?.firstResponder as? NSTextView, responder.hasMarkedText() {
            responder.unmarkText()
        }
        if hasMarkedText() { unmarkText() }
        if let cell = tableCellEditor, cell.hasMarkedText() { cell.unmarkText() }
        prepareImageEditingForHiding()
        commitContent()
        breakUndoCoalescing()
    }

    var mcpInteractionBusy: Bool {
        hasMarkedText() || tableCellEditor != nil || imageCaptionBlock != nil || imageResize != nil || hasPendingLibraryFileWork
    }
    func applyCommandContent(_ next: NoteContent) throws {
        guard isEditable, !mcpInteractionBusy, AudioBlockModel.recording == nil else { throw MCPFailure("busy_editing") }
        try next.validate()
        undoManager?.beginUndoGrouping()
        replaceDocument(next, block: 0, preservingSelection: true)
        undoManager?.endUndoGrouping()
        let length = (string as NSString).length
        if selectedRange().location > length { setSelectedRange(NSRange(location: length, length: 0)) }
    }
    func commandMedia(_ operation: String, blockID: UUID, position: Double?, rate: Float?) throws {
        guard let block = content.blocks.first(where: { $0.id == blockID }), AudioBlockModel.recording == nil else { throw MCPFailure("busy_editing") }
        if let audio = audioModel(for: block) {
            switch operation {
            case "play_media": if !audio.isPlaying { audio.togglePlayback() }; if !audio.isPlaying { throw MCPFailure("asset_unavailable") }
            case "pause_media": audio.pause()
            case "seek_media": guard let position, position <= audio.audio.duration else { throw MCPFailure("invalid_input") }; audio.seek(position / max(0.001, audio.audio.duration))
            case "set_playback": guard let rate else { throw MCPFailure("invalid_input") }; audio.setRate(rate)
            default: throw MCPFailure("unsupported")
            }
        } else if block.video != nil {
            synchronizeVideoModels()
            guard let video = videoModels[blockID] else { throw MCPFailure("asset_unavailable") }
            switch operation {
            case "play_media": guard video.play() != nil else { throw MCPFailure("asset_unavailable") }
            case "pause_media": video.pause()
            case "seek_media": guard let position, position <= video.video.duration, let player = video.player else { throw MCPFailure("invalid_input") }; player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
            case "set_playback": guard let rate, let player = video.player else { throw MCPFailure("invalid_input") }; if player.rate > 0 { player.rate = rate } else { player.defaultRate = rate }
            default: throw MCPFailure("unsupported")
            }
        } else { throw MCPFailure("invalid_input") }
    }

    private(set) var imageControls: ImageBlockControls?
    private var imageResize: (block: NoteBlock, width: CGFloat, side: CGFloat, preview: CGFloat)?
    private var imageCaptionBlock: NoteBlock?
    private var imageControlsScheduled = false
    private var updatingImageControls = false
    var fetchRemoteImage: @Sendable (URL) async throws -> Data = RemoteImageImporter.fetch
    var onRemoteImageCommit: (() -> Bool)?
    private var remoteImageQueue: [UUID] = []
    private var remoteImageTasks: [UUID: (token: UUID, image: UUID, source: String, task: Task<Void, Never>)] = [:]
    var onAudioCommit: (() -> Bool)?
    private var videoModels: [UUID: VideoBlockModel] = [:]
    private var videoViews: [UUID: VideoBlockView] = [:]
    private var videoViewsScheduled = false
    private var updatingVideoViews = false
    var onVideoCommit: (() -> Bool)?
    var onAttachmentCommit: (() -> Bool)?
    private var audioModels: [UUID: AudioBlockModel] = [:]
    private var audioViews: [UUID: NSView] = [:]
    private var audioViewsScheduled = false
    private var updatingAudioViews = false
    var shortcuts: ShortcutSettings = .shared
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
    private var typographyRefresh: Task<Void, Never>?
    var codeThemes = CodeThemeSettings.shared
    var noteColor: NSColor = .labelColor
    private var paperBackground = NotePalette.paperBackground
    private(set) var findBar: NoteFindBar?
    private var findTask: Task<Void, Never>?
    private var findGeneration = 0
    private(set) var findResult = NoteSearch.Result()
    private var findHitsByBlock: [UUID: [NoteSearch.Hit]] = [:]
    private struct FindFieldKey: Hashable { let block: UUID; let field: NoteSearch.Field }
    private struct FindTextLayout {
        let storage: NSTextStorage
        let manager: NSLayoutManager
        let container: NSTextContainer
    }
    private var findAttachmentHits: [UUID: [NoteSearch.Field: [NoteSearch.Hit]]] = [:]
    private var findTextLayouts: [FindFieldKey: FindTextLayout] = [:]
    private var findSnapshot: NoteContent?
    private var findIndex = 0
    private var findBusy = false
    private var findHistoryTargetsNote = false
    var content = NoteContent() { didSet { scheduleNoteSearch(); reconcileRemoteImages() } }
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
    var hasPendingFileImport: Bool { importInProgress }
    var hasPendingLibraryFileWork: Bool { importInProgress || !remoteImageTasks.isEmpty || !remoteImageQueue.isEmpty }
    var hasPendingLibraryWork: Bool {
        hasPendingLibraryFileWork || AudioBlockModel.recording != nil || imageCaptionBlock != nil || imageResize != nil
    }
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
        endImageResize(cancelled: true)
        endImageCaption(cancelled: true)
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
            NotificationCenter.default.addObserver(self, selector: #selector(noteTypographyChanged(_:)), name: NoteStyleSettings.typographyDidChange, object: NoteStyleSettings.shared)
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
        synchronizeAudioModels()
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
        // External revisions enter the existing native undo history. The
        // shared revision files retain the remote version even after an undo.
        let ranges = selectedRanges
        replaceDocument(next, block: 0, preservingSelection: true)
        selectedRanges = ranges.map { value in
            let range = value.rangeValue, length = (string as NSString).length
            let start = min(range.location, length)
            return NSValue(range: NSRange(location: start, length: min(range.length, length - start)))
        }
    }

    private var audioAppearanceRefreshScheduled = false

    func updateColors(_ color: NSColor) {
        guard noteColor != color else { return }
        noteColor = color
        refreshVideoControls()
        scheduleImageControls()
        // updateColors is also called by NSViewRepresentable.updateNSView.
        // Audio controls observe these models, so publish after that transaction.
        if !audioAppearanceRefreshScheduled, !audioModels.isEmpty {
            audioAppearanceRefreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                audioAppearanceRefreshScheduled = false
                for model in audioModels.values { model.objectWillChange.send() }
            }
        }
        blockHandle?.ink = color
        tableControls?.updateColors(color)
        refreshStyles(force: true)
        updateCodeCaretColors()
    }

    func updatePaperBackground(_ color: NSColor) {
        guard paperBackground != color else { return }
        paperBackground = color
        scheduleImageControls()
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

    @objc private func noteTypographyChanged(_ notification: Notification) {
        typographyRefresh?.cancel()
        typographyRefresh = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            // Defer composition safely; no text replacement or undo registration.
            while self?.hasMarkedText() == true || self?.tableCellEditor?.hasMarkedText() == true {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard let self else { return }
            let ranges = self.selectedRanges
            let origin = self.enclosingScrollView?.contentView.bounds.origin
            self.tableLayouts.removeAll()
            self.refreshStyles(force: true)
            self.selectedRanges = ranges
            if let origin, let scroll = self.enclosingScrollView {
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            self.scheduleInsertionPointRefresh()
        }
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
        drawNoteSearch(in: dirtyRect)
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
            case .image, .divider, .table, .audio, .video, .file: return nil
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
        scheduleImageControls()
        // Includes attribute-only edits, undo and marked text, even while the
        // document model deliberately waits for an editing transaction to end.
        invalidateBlockGeometry()
    }

    override func layout() {
        invalidateBlockGeometry()
        super.layout()
        scheduleAudioViews()
        scheduleImageControls()
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
        updateImageControls(at: convert(event.locationInWindow, from: nil))
        updateTableControls(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateCodeToolbar(at: convert(event.locationInWindow, from: nil))
        updateBlockHandle(at: convert(event.locationInWindow, from: nil))
        updateImageControls(at: convert(event.locationInWindow, from: nil))
        updateTableControls(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // Moving from text into the overlay is still inside the same code block.
        updateCodeToolbar(at: convert(event.locationInWindow, from: nil))
        updateBlockHandle(at: convert(event.locationInWindow, from: nil))
        updateImageControls(at: convert(event.locationInWindow, from: nil))
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
        scheduleAudioViews()
        scheduleImageControls()
        // Coalesce geometry updates while leaving the existing overlay visible.
        // Only a confirmed pointer/block change should hide it.
        scheduleCodeToolbarUpdate()
    }

    override func setFrameSize(_ newSize: NSSize) {
        if frame.size != newSize {
            if frame.width != newSize.width, imageResize != nil { endImageResize(cancelled: true) }
            invalidateBlockGeometry()
        }
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
                                     tableLayout: { [unowned self] block, width in self.tableLayout(for: block, width: width) },
                                     audioModel: { [weak self] in self?.audioModel(for: $0) }) { [weak self] asset in
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
        synchronizeAudioModels()
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
        synchronizeAudioModels()
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
        restoreImagePreviewIfNeeded()
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
        synchronizeAudioModels()
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
        let hitIDs = Set(blockSurfaces().filter { $0.rect.contains(point) }.map(\.blockID))
        if event.clickCount == 2, !hasMarkedText(), let block = content.blocks.first(where: { hitIDs.contains($0.id) && $0.attachment != nil }) {
            _ = openAttachment(blockID: block.id); return
        }
        for block in content.blocks where hitIDs.contains(block.id) {
            guard !hasMarkedText(), let image = block.image, let rect = imageFrame(blockID: block.id), rect.contains(point) else { continue }
            if image.isRemotePlaceholder { enqueueRemoteImages([block.id]); return }
            if event.clickCount == 2, (image.caption == nil || point.y < rect.maxY - 28), let link = image.clickableLink { NSWorkspace.shared.open(link); return }
        }
        for block in content.blocks where block.image?.caption != nil {
            if let rect = imageFrame(blockID: block.id), point.y >= rect.maxY - 28, rect.contains(point) {
                beginImageCaption(blockID: block.id); return
            }
        }
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
        else if enclosingScrollView?.isFindBarVisible == true { closeNoteFind() }
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
        if window !== newWindow {
            remoteImageQueue.removeAll()
            for entry in remoteImageTasks.values { entry.task.cancel() }
            remoteImageTasks.removeAll()
            detachVideoViews()
        }
        if window !== newWindow { cancelBlockDrag(); prepareImageEditingForHiding(); imageControls?.removeFromSuperview() }
        if window !== newWindow { dismissSlashMenu(); clearBlockSelection(); codeToolbar?.isHidden = true; blockHandle?.isHidden = true }
        super.viewWillMove(toWindow: newWindow)
    }

    override func scrollWheel(with event: NSEvent) {
        dismissSlashMenu()
        super.scrollWheel(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let action = shortcuts.matchingEditor(event) {
            if !event.isARepeat { performEditorShortcut(action) }
            return true
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if selectedBlockID != nil, !hasMarkedText() {
            if flags == .command {
                switch event.charactersIgnoringModifiers {
                case "c": copy(nil); return true
                case "x": cut(nil); return true
                default: break
                }
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
        return super.performKeyEquivalent(with: event)
    }

    @discardableResult func performEditorShortcut(_ action: EditorShortcutAction) -> Bool {
        if action.isSearch {
            guard !hasMarkedText(), tableCellEditor?.hasMarkedText() != true else { return false }
            switch action {
            case .find: showNoteFind(replacing: false)
            case .replace: showNoteFind(replacing: true)
            case .nextMatch: stepNoteSearch(1)
            case .previousMatch: stepNoteSearch(-1)
            default: break
            }
            return true
        }
        guard isEditable, !hasMarkedText(), tableCellEditor == nil, imageCaptionBlock == nil else { return false }
        let target = selectedBlockID ?? activeSpan?.block.id
        if [.record, .image, .audio, .video].contains(action), selectedBlockID != nil { editSelectedBlock(atEnd: true) }
        switch action {
        case .find, .replace, .nextMatch, .previousMatch: break
        case .record: recordAudio(nil)
        case .image: chooseImage(nil)
        case .audio: chooseAudio(nil)
        case .video: chooseVideo(nil)
        case .blockMenu:
            guard let target, let menu = makeBlockActionMenu(blockID: target) else { return false }
            let rect = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
            let point = window.map { convert($0.convertPoint(fromScreen: rect.origin), from: nil) } ?? .zero
            menu.popUp(positioning: nil, at: point, in: self)
        case .duplicateBlock:
            guard let target else { return false }; return performBlockAction(.duplicate, blockID: target)
        case .moveUp:
            guard let target else { return false }; return performBlockAction(.moveUp, blockID: target)
        case .moveDown:
            guard let target else { return false }; return performBlockAction(.moveDown, blockID: target)
        }
        return true
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
            var entries = NoteBlockKind.allCases.filter { $0 != .file }.map {
                SlashCommandMenu.Entry(kind: $0, title: $0 == .paragraph ? String(localized: "Text", bundle: bundle) : $0 == .audio ? String(localized: "Record Audio", bundle: bundle) : title($0))
            }
            entries.append(.init(kind: .audio, title: String(localized: "Import Audio…", bundle: bundle), importsAudio: true))
            let suggestions = SlashCommandMenu(blockID: blockID, entries: entries, bundle: bundle)
            suggestions.onChoose = { [weak self] kind in
                guard let self else { return }
                let valid = slashContext == context
                dismissSlashMenu()
                guard valid else { return }
                if kind == .image { chooseImage(nil) } else { changeKind(kind) }
            }
            suggestions.onImportAudio = { [weak self] in
                guard let self, slashContext == context else { return }
                dismissSlashMenu(); chooseAudio(nil)
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
        if let links = blockMenu.items.first(where: { ($0.representedObject as? BlockMenuCommand)?.action == .renderTextLinks }) {
            blockMenu.removeItem(links); menu.addItem(links)
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
        for kind in NoteBlockKind.allCases where kind != .image && kind != .audio && kind != .video && kind != .file {
            let item = NSMenuItem(title: title(kind), action: #selector(selectKind(_:)), keyEquivalent: "")
            item.representedObject = kind.rawValue
            item.target = self
            item.state = activeSpan?.block.kind == kind ? .on : .off
            item.image = BlockMenuIcon.image(for: kind)
            menu.addItem(item)
        }
        add(menu, String(localized: "Import Video…", bundle: bundle), #selector(chooseVideo(_:)))
        add(menu, String(localized: "Import Attachments…", bundle: bundle), #selector(chooseAttachments(_:)))
        add(menu, String(localized: "Record Audio", bundle: bundle), #selector(recordAudio(_:)))
        add(menu, String(localized: "Import Audio…", bundle: bundle), #selector(chooseAudio(_:)))
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
        let editorAction: EditorShortcutAction? = action == #selector(recordAudio(_:)) ? .record
            : action == #selector(chooseImage(_:)) ? .image : action == #selector(chooseAudio(_:)) ? .audio
            : action == #selector(chooseVideo(_:)) ? .video : nil
        if let editorAction {
            let binding = shortcuts.binding(editorAction)
            item.keyEquivalent = binding.key; item.keyEquivalentModifierMask = binding.modifiers
        }
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
        case .file: String(localized: "Attachment", bundle: bundle)
        case .video: String(localized: "Video", bundle: bundle)
        case .audio: String(localized: "Audio", bundle: bundle)
        case .image: String(localized: "Image", bundle: bundle)
        }
    }

    @objc private func selectKind(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = NoteBlockKind(rawValue: raw) else { return }
        changeKind(kind)
    }

    func changeKind(_ kind: NoteBlockKind) {
        if kind == .file { chooseAttachments(nil); return }
        if kind == .video { chooseVideo(nil); return }
        if kind == .audio { recordAudio(nil); return }
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
        if copyAudioSelection() != nil { return }
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
        if selectedBlockID == nil, let copied = copyAudioSelection() {
            guard copied, isEditable, !hasMarkedText() else { return }
            super.insertText("", replacementRange: selectedRange())
            return
        }
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
        if importAttachments(from: board) { return }
        if activeSpan?.block.kind == .code, let text = board.string(forType: .string) {
            insertPastedText(text, interpretingMarkdown: false); return
        }
        if let data = board.data(forType: Self.pasteboardType),
           let value = try? JSONDecoder().decode(NoteContent.self, from: data), (try? value.validate()) != nil {
            if !insertPastedBlocks(value) {
                if value.blocks.contains(where: { $0.attachment != nil }) {
                    attachmentError(NoteFileError.missingAttachment.description(bundle: bundle))
                } else { insertPastedText(value.plainText, interpretingMarkdown: false) }
            }
            return
        }
        if importVideo(from: board) || importAudio(from: board) || importImages(from: board) { return }
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
           let parsed = MarkdownPasteParser.parse(text) {
            let previousIDs = Set(content.blocks.map(\.id))
            if insertPastedBlocks(parsed) {
                let added = content.blocks.filter { !previousIDs.contains($0.id) && $0.image?.isRemotePlaceholder == true }.map(\.id)
                if onRemoteImageCommit?() != false { enqueueRemoteImages(added) }
                return
            }
        }
        if !hasMarkedText() { updateTypingStyle(preservingInlineFormat: true) }
        // Ordinary text and the explicit plain-text command remain literal.
        insertText(NSAttributedString(string: text, attributes: typingAttributes), replacementRange: selectedRange())
    }

    @discardableResult
    func insertPastedBlocks(_ value: NoteContent) -> Bool {
        guard isEditable, !hasMarkedText(), tableCellEditor == nil, (try? value.validate()) != nil else { return false }
        for attachment in value.blocks.compactMap(\.attachment) {
            guard let file, FileManager.default.fileExists(atPath: file.attachmentURL(attachment).path) else { return false }
        }
        for video in value.blocks.compactMap(\.video) {
            guard let file, FileManager.default.fileExists(atPath: file.videoURL(video).path) else { return false }
        }
        for audio in value.blocks.compactMap(\.audio) {
            guard let file, FileManager.default.fileExists(atPath: file.audioURL(audio).path) else { return false }
        }
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
        guard file?.libraryPath?.writable != false, !importInProgress, let window, let target = activeSpan?.block.id else { return }
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
        if attachmentURLs(from: sender.draggingPasteboard) != nil {
            return isEditable && !hasMarkedText() && !importInProgress && tableCellEditor == nil ? .copy : []
        }
        if videoURL(from: sender.draggingPasteboard) != nil {
            return isEditable && !hasMarkedText() && !importInProgress ? .copy : []
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
        if attachmentURLs(from: sender.draggingPasteboard) != nil {
            return isEditable && !hasMarkedText() && !importInProgress && tableCellEditor == nil
        }
        if videoURL(from: sender.draggingPasteboard) != nil {
            return isEditable && !hasMarkedText() && !importInProgress && tableCellEditor?.hasMarkedText() != true
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
        return importAttachments(from: sender.draggingPasteboard) || importVideo(from: sender.draggingPasteboard) || importAudio(from: sender.draggingPasteboard) || importImages(from: sender.draggingPasteboard) || super.performDragOperation(sender)
    }

    private func importImage(url: URL? = nil, data: Data? = nil, target: UUID, command: SlashCommandContext? = nil) {
        guard file?.libraryPath?.writable != false, !importInProgress, let directory = file?.assetsURL else { return }
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
        endImageResize(cancelled: true)
        endImageCaption(cancelled: false)
        imageControls?.isHidden = true
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
            let editorAction: EditorShortcutAction? = action == .duplicate ? .duplicateBlock : action == .moveUp ? .moveUp : action == .moveDown ? .moveDown : nil
            if let editorAction {
                let binding = shortcuts.binding(editorAction)
                result.keyEquivalent = binding.key; result.keyEquivalentModifierMask = binding.modifiers
            }
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
        if MarkdownTextLinks.render(block) != nil {
            menu.addItem(item(String(localized: "Render Text Links", bundle: bundle), .renderTextLinks, symbol: "link"))
        }
        if block.kind == .code {
            menu.addItem(.separator())
            appendCodeActions(to: menu, blockID: blockID)
        }
        if block.kind == .image {
            if block.image?.isRemotePlaceholder == true {
                menu.addItem(item(String(localized: "Retry image download", bundle: bundle), .retryRemoteImage, symbol: "arrow.clockwise", enabled: remoteImageTasks[blockID] == nil))
                menu.addItem(item(String(localized: "Restore image Markdown", bundle: bundle), .restoreImageMarkdown, symbol: "text.alignleft"))
            }
            if let link = block.image?.link {
                let entry = item(String(localized: "Open image link", bundle: bundle), .openImageLink, symbol: "arrow.up.right.square", enabled: block.image?.clickableLink != nil)
                entry.toolTip = link; menu.addItem(entry)
            }
            menu.addItem(item(String(localized: "Edit image caption", bundle: bundle), .imageCaption, symbol: "text.below.photo"))
            menu.addItem(item(String(localized: "Reset image size", bundle: bundle), .resetImageSize, symbol: "arrow.up.left.and.arrow.down.right"))
            if block.image?.caption != nil {
                menu.addItem(item(String(localized: "Remove image caption", bundle: bundle), .removeImageCaption))
            }
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
            menu.addItem(item(String(localized: "Export Image…", bundle: bundle), .exportMedia, symbol: "square.and.arrow.up", enabled: block.image?.isRemotePlaceholder != true))
            menu.addItem(item(String(localized: "Copy Image", bundle: bundle), .copyImage, symbol: "photo.on.rectangle", key: "c", enabled: block.image?.isRemotePlaceholder != true))
        }
        if block.kind == .file {
            menu.addItem(item(String(localized: "Open Attachment", bundle: bundle), .openAttachment, symbol: "arrow.up.right.square"))
            menu.addItem(item(String(localized: "Export Attachment…", bundle: bundle), .exportMedia, symbol: "square.and.arrow.up"))
            menu.addItem(.separator())
        }
        if block.kind == .video {
            menu.addItem(item(String(localized: "Export Video…", bundle: bundle), .exportMedia, symbol: "square.and.arrow.up"))
        }
        if block.kind == .audio {
            menu.addItem(item(String(localized: "Export Audio…", bundle: bundle), .exportMedia, symbol: "square.and.arrow.up"))
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
        if (action == .copy || action == .duplicate), let model = audioModels[blockID], model.isRecording, !model.finish() { return false }
        var next = content
        var destination = index
        var selectedID: UUID? = blockID
        switch action {
        case .renderTextLinks:
            guard let converted = MarkdownTextLinks.render(next.blocks[index]) else { return false }
            let oldOffset = max(0, selectedRange().location - spans[index].textRange.location)
            next.blocks[index] = converted.block
            replaceDocument(next, block: index, offset: converted.offset(oldOffset))
            undoManager?.setActionName(String(localized: "Render Text Links", bundle: bundle))
            return true
        case .retryRemoteImage: enqueueRemoteImages([blockID]); return true
        case .openImageLink:
            guard let link = next.blocks[index].image?.clickableLink else { return false }
            return NSWorkspace.shared.open(link)
        case .restoreImageMarkdown:
            guard let text = next.blocks[index].image?.sourceMarkdown else { return false }
            next.blocks[index] = NoteBlock(id: blockID, text: text)
        case .openAttachment: return openAttachment(blockID: blockID)
        case .exportMedia: return exportMedia(blockID: blockID)
        case .imageCaption: beginImageCaption(blockID: blockID); return true
        case .resetImageSize: resetImageSize(blockID: blockID); return true
        case .removeImageCaption:
            guard var image = next.blocks[index].image else { return false }
            image.caption = nil; return updateImage(image, blockID: blockID)
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
            if content.blocks[index].audio != nil || content.blocks[index].video != nil || content.blocks[index].attachment != nil {
                guard let file else { return false }
                do { try NoteClipboard.copy(NoteContent(blocks: [content.blocks[index]]), file: file); return true }
                catch {
                    if content.blocks[index].attachment != nil { attachmentError(error.localizedDescription) }
                    else if content.blocks[index].video != nil { videoError(error.localizedDescription) }
                    else { audioError(error.localizedDescription) }
                    return false
                }
            }
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
        if let previous, previous.typography == NoteStyleSettings.shared.values.typography, previous.table == table, previous.width == max(80, width) { return previous }
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
        synchronizeAudioModels()
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

// MARK: - Local audio attachments
extension PaperTextView {
    @discardableResult func exportMedia(blockID: UUID) -> Bool {
        guard isEditable, !hasMarkedText(), tableCellEditor?.hasMarkedText() != true,
              let file, let window,
              let block = content.blocks.first(where: { $0.id == blockID }) else { return false }
        if block.audio?.isDraft == true {
            guard let model = audioModel(for: block), model.finish() else { return false }
        }
        // Finishing a draft updates the document. Re-read this exact block after saving.
        guard let current = content.blocks.first(where: { $0.id == blockID }) else { return false }
        do {
            let export: MediaExport
            if let attachment = current.attachment {
                export = try .attachment(at: file.attachmentURL(attachment), attachment: attachment)
            } else if current.kind == .image, let image = current.image {
                export = try .image(at: file.imageURL(image.id, original: true), name: image.name,
                                    fallback: String(localized: "Image", bundle: bundle), isSVG: image.isSVG == true)
            } else if current.kind == .video, let video = current.video {
                export = try .video(at: file.videoURL(video), video: video, fallback: String(localized: "Video", bundle: bundle))
            } else if current.kind == .audio, let audio = current.audio {
                export = try .audio(at: file.audioURL(audio), audio: audio,
                                    fallback: String(localized: "Audio", bundle: bundle))
            } else { return false }
            export.present(in: window)
            return true
        } catch {
            MediaExport.showError(error, in: window)
            return false
        }
    }

    private func audioModel(for block: NoteBlock) -> AudioBlockModel? {
        guard let audio = block.audio, let file else { return nil }
        if let existing = audioModels[block.id] { existing.update(audio); return existing }
        let model = AudioBlockModel(blockID: block.id, audio: audio, file: file, editor: self)
        audioModels[block.id] = model
        return model
    }
    private func synchronizeAudioModels() {
        synchronizeVideoModels()
        let ids = Set(content.blocks.filter { $0.audio != nil }.map(\.id))
        for id in Array(audioModels.keys) where !ids.contains(id) {
            audioModels.removeValue(forKey: id)?.stop()
            audioViews.removeValue(forKey: id)?.removeFromSuperview()
        }
        scheduleAudioViews()
    }
    private func scheduleAudioViews() {
        scheduleVideoViews()
        guard !audioViewsScheduled, !audioModels.isEmpty || content.blocks.contains(where: { $0.audio != nil }) else { return }
        audioViewsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            audioViewsScheduled = false
            synchronizeAudioViews()
        }
    }
    func synchronizeAudioViews() {
        guard !updatingAudioViews else { return }
        updatingAudioViews = true
        defer { updatingAudioViews = false }
        var visible: Set<UUID> = []
        let surfaces = Set(blockSurfaces().map(\.blockID))
        for span in spans where span.block.audio != nil && surfaces.contains(span.block.id) {
            guard let manager = textLayoutManager, let source = manager.textContentManager,
                  let location = source.location(source.documentRange.location, offsetBy: span.textRange.location),
                  let fragment = manager.textLayoutFragment(for: location) else { continue }
            let attachment = fragment.frameForTextAttachment(at: location)
            let rect = attachment.offsetBy(dx: textContainerOrigin.x + fragment.layoutFragmentFrame.minX,
                                           dy: textContainerOrigin.y + fragment.layoutFragmentFrame.minY)
            guard rect.width > 0, rect.height > 0, rect.intersects(visibleRect), let model = audioModel(for: span.block) else { continue }
            visible.insert(span.block.id)
            let view: NSView
            if let existing = audioViews[span.block.id] { view = existing }
            else { view = model.makePlayerView(); audioViews[span.block.id] = view; addSubview(view, positioned: .above, relativeTo: nil) }
            if view.frame != rect { view.frame = rect }
        }
        for id in Array(audioViews.keys) where !visible.contains(id) { audioViews.removeValue(forKey: id)?.removeFromSuperview() }
    }
    @discardableResult func updateAudio(_ audio: NoteAudio, blockID: UUID) -> Bool {
        guard isEditable, !hasMarkedText(), tableCellEditor?.hasMarkedText() != true, audio.isValid,
              let index = content.blocks.firstIndex(where: { $0.id == blockID && $0.audio?.id == audio.id }) else { return false }
        var next = content; next.blocks[index].audio = audio
        replaceDocument(next, block: index, preservingSelection: true)
        return onAudioCommit?() ?? true
    }
    func deleteAudioBlock(_ id: UUID) { _ = performBlockAction(.delete, blockID: id) }
    @discardableResult func prepareAudioForHiding() -> Bool {
        detachVideoViews()
        var saved = true
        for model in Array(audioModels.values) {
            if model.isRecording, !model.finish() { saved = false }
            model.pause()
        }
        return saved
    }
    func refreshCloudResources() {
        images.removeAllObjects()
        refreshStyles(force: true)
        for view in videoViews.values { view.refreshPoster() }
    }
    func releaseMediaForLibraryChange() { detachVideoViews(); for model in audioModels.values { model.releaseForLibraryChange() } }
    func stopAudio() { detachVideoViews(); for model in audioModels.values { model.stop() } }

    private func copyAudioSelection() -> Bool? {
        let range = selectedRange()
        guard range.length > 0, NSMaxRange(range) <= attributedString().length else { return nil }
        func selectedContent() -> NoteContent {
            NoteContent(blocks: BlockTextCodec.read(attributedString().attributedSubstring(from: range), typing: typingAttributes).map(\.block))
        }
        let selected = selectedContent()
        guard selected.blocks.contains(where: { $0.audio != nil || $0.video != nil || $0.attachment != nil }) else { return nil }
        guard let file, !hasMarkedText() else { return false }
        for block in selected.blocks {
            if let model = audioModels[block.id], model.isRecording, !model.finish() { return false }
        }
        do { try NoteClipboard.copy(selectedContent(), file: file); return true }
        catch {
            if selected.blocks.contains(where: { $0.attachment != nil }) { attachmentError(error.localizedDescription) }
            else if selected.blocks.contains(where: { $0.video != nil }) { videoError(error.localizedDescription) }
            else { audioError(error.localizedDescription) }
            return false
        }
    }

    private func audioError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = String(localized: "Audio", bundle: bundle); alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
    @objc func recordAudio(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), tableCellEditor?.hasMarkedText() != true,
              let source = activeSpan?.block, file != nil else { return }
        guard AudioBlockModel.recording == nil, !AudioBlockModel.requestingRecording else {
            audioError(String(localized: "Finish the current recording before starting another.", bundle: bundle)); return
        }
        let context = slashContext
        AudioBlockModel.requestingRecording = true
        Task { [weak self] in
            defer { AudioBlockModel.requestingRecording = false }
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard let self else { return }
            guard allowed else { audioError(String(localized: "Allow microphone access for Foldpin in System Settings to record audio.", bundle: bundle)); return }
            guard isEditable, !hasMarkedText(), content.blocks.contains(source), window?.isVisible == true else { return }
            startAuthorizedRecording(source: source, context: context)
        }
    }
    func startAuthorizedRecording(source: NoteBlock? = nil, context: SlashCommandContext? = nil) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              AudioBlockModel.recording == nil, isEditable, !hasMarkedText(), tableCellEditor?.hasMarkedText() != true,
              let source = source ?? activeSpan?.block, content.blocks.contains(source), let file,
              window?.isVisible == true else { return }
            do {
                try FileManager.default.createDirectory(at: file.assetsURL, withIntermediateDirectories: true)
                let draft = NoteAudio(name: String(localized: "Voice Recording", bundle: bundle), fileExtension: "m4a", duration: 0, isDraft: true)
                let recorder = try AVAudioRecorder(url: file.audioURL(draft), settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
                guard recorder.prepareToRecord() else { throw CocoaError(.fileWriteUnknown) }
                guard let id = insertAudio(draft, source: source, context: context),
                      let model = audioModels[id] else { recorder.stop(); return }
                guard onAudioCommit?() != false else { recorder.stop(); model.error = "Audio could not be saved. Your recording file is kept; retry saving."; return }
                model.start(recorder)
            } catch { audioError(String(localized: "Could not start recording. Your draft is kept.", bundle: bundle)) }
    }
    @objc func chooseAudio(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), let source = activeSpan?.block, let window else { return }
        let context = slashContext
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            self?.importAudio(url: url, source: source, context: context)
        }
    }
    private func importAudio(from board: NSPasteboard) -> Bool {
        guard let source = activeSpan?.block,
              let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              let url = urls.first, let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
              type.conforms(to: .audio) else { return false }
        importAudio(url: url, source: source); return true
    }
    private func importAudio(url: URL, source: NoteBlock, context: SlashCommandContext? = nil) {
        guard file?.libraryPath?.writable != false, !importInProgress, let file, isEditable else { return }
        importInProgress = true
        let directory = file.assetsURL
        Task { [weak self] in
            do {
                let audio = try await Task.detached(priority: .userInitiated) {
                    try NoteAudioImporter.prepare(url: url, directory: directory)
                }.value
                guard let self else { return }
                importInProgress = false
                guard let id = insertAudio(audio, source: source, context: context) else {
                    audioError(String(localized: "The insertion block changed. Import the audio again; the source file is unchanged.", bundle: bundle)); return
                }
                if onAudioCommit?() == false {
                    audioModels[id]?.error = "Audio could not be saved. Your recording file is kept; retry saving."
                }
            } catch {
                guard let self else { return }
                importInProgress = false
                audioError(String(localized: "Could not import audio. Choose a readable audio file under 500 MB.", bundle: bundle))
            }
        }
    }
    @discardableResult private func insertAudio(_ audio: NoteAudio, source: NoteBlock, context: SlashCommandContext?) -> UUID? {
        guard isEditable, !hasMarkedText(), tableCellEditor?.hasMarkedText() != true,
              let index = content.blocks.firstIndex(of: source) else { return nil }
        let block = NoteBlock(kind: .audio, audio: audio)
        if let context {
            guard let insertion = context.inserting(block, in: content), applySlashCommand(block, context: context) else { return nil }
            return insertion.content.blocks[insertion.index].id
        }
        var next = content
        let destination = source.text.isEmpty && !source.kind.isAttachment ? index : index + 1
        if destination == index { next.blocks[index] = block } else { next.blocks.insert(block, at: destination) }
        if destination == next.blocks.count - 1 { next.blocks.append(NoteBlock()) }
        replaceDocument(next, block: destination + 1)
        return block.id
    }
}

// MARK: - Image display size and captions
extension PaperTextView {
    func imageFrame(blockID: UUID) -> NSRect? {
        guard let span = spans.first(where: { $0.block.id == blockID && $0.block.image != nil }),
              let manager = textLayoutManager, let source = manager.textContentManager,
              let location = source.location(source.documentRange.location, offsetBy: span.textRange.location),
              let end = source.location(location, offsetBy: 1), let range = NSTextRange(location: location, end: end) else { return nil }
        // Undo invalidates the fragment before the next viewport pass. Ask for
        // this one attachment so controls work immediately after restoration.
        manager.ensureLayout(for: range)
        guard let fragment = manager.textLayoutFragment(for: location) else { return nil }
        let rect = fragment.frameForTextAttachment(at: location)
        guard rect.width > 0, rect.height > 0 else { return nil }
        return rect.offsetBy(dx: textContainerOrigin.x + fragment.layoutFragmentFrame.minX,
                             dy: textContainerOrigin.y + fragment.layoutFragmentFrame.minY)
    }
    private func scheduleImageControls() {
        guard !imageControlsScheduled, imageControls != nil else { return }
        imageControlsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            imageControlsScheduled = false
            updateImageControls(at: window.map { self.convert($0.mouseLocationOutsideOfEventStream, from: nil) })
        }
    }
    func updateImageControls(at point: NSPoint?) {
        guard !updatingImageControls, imageControls?.isPresentingMenu != true || imageCaptionBlock != nil else { return }
        updatingImageControls = true
        defer { updatingImageControls = false }
        guard isEditable, !hasMarkedText(), tableCellEditor?.hasMarkedText() != true, !isHiddenOrHasHiddenAncestor,
              blockDragState == nil else { imageControls?.isHidden = true; return }
        let heldID = imageResize?.block.id ?? imageCaptionBlock?.id
            ?? (point.map { imageControls?.containsControls($0) == true } == true ? imageControls?.blockID : nil)
        let candidate = content.blocks.first { block in
            guard block.image != nil else { return false }
            if let heldID { return block.id == heldID }
            guard let point, visibleRect.contains(point), let rect = imageFrame(blockID: block.id) else { return false }
            return rect.insetBy(dx: -3, dy: -3).contains(point)
        }
        guard let block = candidate, var image = block.image, let rect = imageFrame(blockID: block.id) else {
            imageControls?.isHidden = true; return
        }
        if let resize = imageResize { image.displayWidth = Double(resize.preview) }
        if imageCaptionBlock != nil, image.caption == nil { image.caption = "" }
        let controls = imageControls ?? ImageBlockControls(editor: self)
        imageControls = controls; controls.blockID = block.id
        let parent: NSView = enclosingScrollView ?? self
        if controls.superview !== parent { controls.removeFromSuperview(); parent.addSubview(controls, positioned: .above, relativeTo: nil) }
        if controls.frame != parent.bounds { controls.frame = parent.bounds }
        controls.isHidden = false
        controls.update(image: image, frame: rect, viewport: visibleRect, ink: noteColor,
                        background: noteColor == NotePalette.paperText ? paperBackground : .textBackgroundColor, bundle: bundle)
    }
    @discardableResult func updateImage(_ image: NoteImage, blockID: UUID) -> Bool {
        guard isEditable, !hasMarkedText(), tableCellEditor?.hasMarkedText() != true, image.isValid,
              let index = content.blocks.firstIndex(where: { $0.id == blockID && $0.image?.id == image.id }) else { return false }
        if content.blocks[index].image == image { return true }
        var next = content; next.blocks[index].image = image
        replaceDocument(next, block: index, preservingSelection: true)
        return true
    }
    func resetImageSize(blockID: UUID) {
        guard var image = content.blocks.first(where: { $0.id == blockID })?.image else { return }
        image.displayWidth = nil; _ = updateImage(image, blockID: blockID)
    }
    func beginImageResize(blockID: UUID, side: CGFloat) -> Bool {
        guard isEditable, !hasMarkedText(), tableCellEditor?.hasMarkedText() != true, imageCaptionBlock == nil,
              let block = content.blocks.first(where: { $0.id == blockID && $0.image != nil }),
              let rect = imageFrame(blockID: blockID) else { return false }
        endTableCellEditing(); dismissSlashMenu()
        imageResize = (block, rect.width, side, rect.width)
        return true
    }
    func previewImageResize(delta: CGFloat) {
        guard var state = imageResize, content.blocks.contains(state.block), var image = state.block.image else {
            endImageResize(cancelled: true); return
        }
        let available = max(40, bounds.width - 2 * textContainerInset.width)
        // Image stays centered, so the two edges move symmetrically.
        state.preview = min(available, max(40, state.width + 2 * delta * state.side))
        imageResize = state; image.displayWidth = Double(state.preview)
        previewImage(image, blockID: state.block.id)
        updateImageControls(at: nil)
    }
    /// Change the display attachment only, never the model/metadata/UndoManager.
    private func previewImage(_ image: NoteImage, blockID: UUID) {
        guard let span = spans.first(where: { $0.block.id == blockID }), let storage = textStorage,
              span.textRange.length == 1, NSMaxRange(span.textRange) <= storage.length else { return }
        var block = span.block; block.image = image
        let rendered = render(NoteContent(blocks: [block]))
        guard let attachment = rendered.attribute(.attachment, at: 0, effectiveRange: nil) else { return }
        applying = true
        storage.addAttribute(.attachment, value: attachment, range: span.textRange)
        applying = false
        invalidateBlockGeometry()
        if let manager = textLayoutManager, let source = manager.textContentManager {
            manager.ensureLayout(for: source.documentRange)
        }
        needsDisplay = true
    }
    private func restoreImagePreviewIfNeeded() {
        if let state = imageResize, content.blocks.contains(state.block), var image = state.block.image {
            image.displayWidth = Double(state.preview)
            previewImage(image, blockID: state.block.id)
        } else if let block = imageCaptionBlock, content.blocks.contains(block), var image = block.image {
            image.caption = image.caption ?? ""
            previewImage(image, blockID: block.id)
        }
    }
    func endImageResize(cancelled: Bool) {
        guard let state = imageResize else { return }
        imageResize = nil
        imageControls?.leftGrip.cancelTracking(); imageControls?.rightGrip.cancelTracking()
        guard content.blocks.contains(state.block), var image = state.block.image else { scheduleImageControls(); return }
        previewImage(image, blockID: state.block.id)
        if !cancelled, abs(state.preview - state.width) > 0.5 {
            image.displayWidth = Double(state.preview)
            _ = updateImage(image, blockID: state.block.id)
            undoManager?.setActionName(String(localized: "Resize image", bundle: bundle))
        }
        if window?.firstResponder is ImageResizeGrip { window?.makeFirstResponder(self) }
        scheduleImageControls()
    }
    func beginImageCaption(blockID: UUID) {
        guard isEditable, !hasMarkedText(), tableCellEditor?.hasMarkedText() != true else { return }
        endImageResize(cancelled: true)
        endImageCaption(cancelled: false)
        guard let block = content.blocks.first(where: { $0.id == blockID }), var image = block.image else { return }
        endTableCellEditing(); clearBlockSelection(); dismissSlashMenu()
        imageCaptionBlock = block
        let controls = imageControls ?? ImageBlockControls(editor: self)
        imageControls = controls; controls.blockID = blockID; controls.editingCaption = true
        controls.captionField.stringValue = image.caption ?? ""
        if image.caption == nil { image.caption = ""; previewImage(image, blockID: blockID) }
        updateImageControls(at: nil)
        controls.captionField.isHidden = false
        controls.captionField.selectText(nil)
    }
    func endImageCaption(cancelled: Bool) {
        guard let original = imageCaptionBlock, let controls = imageControls else { return }
        // Finish IME before capturing the field. No document changes happen for
        // intermediate composition strings.
        let fieldEditor = controls.captionField.currentEditor() as? NSTextView
        fieldEditor?.unmarkText()
        let value = controls.captionField.stringValue
        imageCaptionBlock = nil; controls.editingCaption = false
        if fieldEditor != nil { window?.makeFirstResponder(self) }
        controls.captionField.isHidden = true
        guard content.blocks.contains(original), var image = original.image else { return }
        previewImage(image, blockID: original.id)
        if !cancelled {
            image.caption = String(value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").prefix(4096))
            _ = updateImage(image, blockID: original.id)
            undoManager?.setActionName(String(localized: "Edit image caption", bundle: bundle))
        }
        scheduleImageControls()
    }
    func refreshImageLanguage() {
        refreshStyles(force: true, imagesOnly: true)
        scheduleImageControls()
    }
    func prepareImageEditingForHiding() {
        if enclosingScrollView?.isFindBarVisible == true { closeNoteFind(restoreFocus: false) }
        endImageResize(cancelled: true)
        endImageCaption(cancelled: false)
    }
}

// MARK: - Local video attachments
extension PaperTextView {
    private func synchronizeVideoModels() {
        let blocks = content.blocks.filter { $0.video != nil }
        let ids = Set(blocks.map(\.id))
        for id in Array(videoModels.keys) where !ids.contains(id) {
            if let view = videoViews.removeValue(forKey: id) { view.detach(); view.removeFromSuperview() }
            videoModels.removeValue(forKey: id)?.detach()
        }
        for block in blocks {
            guard let video = block.video else { continue }
            if let existing = videoModels[block.id], existing.video.id != video.id {
                videoViews.removeValue(forKey: block.id)?.removeFromSuperview()
                videoModels.removeValue(forKey: block.id)?.detach()
            }
            videoModels[block.id]?.video = video
        }
        scheduleVideoViews()
    }
    private func scheduleVideoViews() {
        guard !videoViewsScheduled, !videoViews.isEmpty || content.blocks.contains(where: { $0.video != nil }) else { return }
        videoViewsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            videoViewsScheduled = false
            synchronizeVideoViews()
        }
    }
    func synchronizeVideoViews() {
        guard !updatingVideoViews else { return }
        updatingVideoViews = true
        defer { updatingVideoViews = false }
        guard let file, window != nil, !isHiddenOrHasHiddenAncestor else { detachVideoViews(); return }
        var visible: Set<UUID> = []
        let surfaces = Set(blockSurfaces().map(\.blockID))
        for span in spans where span.block.video != nil && surfaces.contains(span.block.id) {
            guard let video = span.block.video, let manager = textLayoutManager, let source = manager.textContentManager,
                  let location = source.location(source.documentRange.location, offsetBy: span.textRange.location),
                  let fragment = manager.textLayoutFragment(for: location) else { continue }
            let rect = fragment.frameForTextAttachment(at: location)
                .offsetBy(dx: textContainerOrigin.x + fragment.layoutFragmentFrame.minX,
                          dy: textContainerOrigin.y + fragment.layoutFragmentFrame.minY)
            guard rect.width > 0, rect.height > 0, rect.intersects(visibleRect) else { continue }
            visible.insert(span.block.id)
            let view: VideoBlockView
            if let existing = videoViews[span.block.id] { view = existing }
            else {
                let model = videoModels[span.block.id] ?? VideoBlockModel(blockID: span.block.id, video: video, file: file)
                videoModels[span.block.id] = model
                view = VideoBlockView(model: model, editor: self)
                videoViews[span.block.id] = view
                addSubview(view, positioned: .above, relativeTo: nil)
            }
            if view.frame != rect { view.frame = rect }
            view.refresh()
        }
        for id in Array(videoViews.keys) where !visible.contains(id) {
            if let view = videoViews.removeValue(forKey: id) { view.detach(); view.removeFromSuperview() }
        }
    }
    private func detachVideoViews() {
        for view in videoViews.values { view.detach(); view.removeFromSuperview() }
        videoViews.removeAll()
    }
    func refreshVideoControls() { for view in videoViews.values { view.refresh() } }
    private func videoError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = String(localized: "Video", bundle: bundle)
        alert.informativeText = message; alert.beginSheetModal(for: window)
    }
    @objc func chooseVideo(_ sender: Any?) {
        guard file?.libraryPath?.writable != false, !importInProgress, isEditable, !hasMarkedText(), tableCellEditor?.hasMarkedText() != true,
              let source = activeSpan?.block, let window else { return }
        let context = slashContext
        let panel = NSOpenPanel()
        panel.allowedContentTypes = NoteVideo.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importVideo(url: url, source: source, context: context)
        }
    }
    private func videoURL(from board: NSPasteboard) -> URL? {
        guard let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              let url = urls.first, url.isFileURL, NoteVideo.extensions.contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }
    private func importVideo(from board: NSPasteboard) -> Bool {
        guard let source = activeSpan?.block, let url = videoURL(from: board) else { return false }
        importVideo(url: url, source: source); return true
    }
    private func importVideo(url: URL, source: NoteBlock, context: SlashCommandContext? = nil) {
        guard file?.libraryPath?.writable != false, !importInProgress, let file, isEditable, !hasMarkedText(), tableCellEditor?.hasMarkedText() != true else { return }
        importInProgress = true
        let directory = file.assetsURL
        Task { [weak self] in
            do {
                let video = try await Task.detached(priority: .userInitiated) {
                    try await NoteVideoImporter.prepare(url: url, directory: directory)
                }.value
                guard let self else {
                    Self.removeUninsertedVideo(video, directory: directory); return
                }
                importInProgress = false
                guard insertVideo(video, source: source, context: context) != nil else {
                    Self.removeUninsertedVideo(video, directory: directory)
                    videoError(String(localized: "The insertion block changed. Import the video again; the source file is unchanged.", bundle: bundle)); return
                }
                if onVideoCommit?() == false {
                    videoError(String(localized: "The video could not be saved. Its file is kept; retry saving the note.", bundle: bundle))
                }
            } catch {
                guard let self else { return }
                importInProgress = false
                videoError(String(localized: "Could not import video. Choose a playable MP4, MOV, or M4V file under 1 GB.", bundle: bundle))
            }
        }
    }
    private static func removeUninsertedVideo(_ video: NoteVideo, directory: URL) {
        for suffix in ["." + video.fileExtension, ".poster.jpg"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(video.id.uuidString + suffix))
        }
    }
    @discardableResult func insertVideo(_ video: NoteVideo, source: NoteBlock, context: SlashCommandContext? = nil) -> UUID? {
        guard video.isValid, isEditable, !hasMarkedText(), tableCellEditor?.hasMarkedText() != true,
              let index = content.blocks.firstIndex(of: source) else { return nil }
        let block = NoteBlock(kind: .video, video: video)
        if let context {
            guard let insertion = context.inserting(block, in: content), applySlashCommand(block, context: context) else { return nil }
            return insertion.content.blocks[insertion.index].id
        }
        var next = content
        let destination = source.text.isEmpty && !source.kind.isAttachment ? index : index + 1
        if destination == index { next.blocks[index] = block } else { next.blocks.insert(block, at: destination) }
        if destination == next.blocks.count - 1 { next.blocks.append(NoteBlock()) }
        replaceDocument(next, block: destination + 1)
        return block.id
    }
}

// MARK: - Per-note find. Query state and highlights never enter the document.
extension PaperTextView {
    func showNoteFind(replacing: Bool) {
        guard !hasMarkedText(), tableCellEditor?.hasMarkedText() != true, let scroll = enclosingScrollView else { return }
        endTableCellEditing(); endImageCaption(cancelled: false); dismissSlashMenu()
        let bar: NoteFindBar
        if let findBar { bar = findBar } else {
            bar = NoteFindBar(); findBar = bar
            bar.onQuery = { [weak self] in self?.findIndex = 0; self?.scheduleNoteSearch() }
            bar.onDraftEdit = { [weak self] in self?.findHistoryTargetsNote = false }
            bar.onStep = { [weak self] in self?.stepNoteSearch($0) }
            bar.onReplace = { [weak self] in self?.replaceNoteSearch(all: $0) }
            bar.onClose = { [weak self] in self?.closeNoteFind() }
        }
        bar.refreshLanguage(); bar.replacing = replacing
        scroll.findBarPosition = .aboveContent
        scroll.findBarView = bar; scroll.isFindBarVisible = true; scroll.findBarViewDidChangeHeight()
        window?.makeFirstResponder(bar.query)
        scheduleNoteSearch()
    }

    func closeNoteFind(restoreFocus: Bool = true) {
        findTask?.cancel(); findTask = nil; findGeneration += 1
        findHistoryTargetsNote = false
        findResult = .init(); findHitsByBlock = [:]; findAttachmentHits = [:]; findTextLayouts = [:]; findSnapshot = nil; findBusy = false
        enclosingScrollView?.isFindBarVisible = false
        needsDisplay = true
        if restoreFocus { window?.makeFirstResponder(self) }
    }

    func scheduleNoteSearch() {
        guard let bar = findBar, enclosingScrollView?.isFindBarVisible == true else { return }
        findTask?.cancel(); findGeneration += 1
        let generation = findGeneration
        findResult = .init(); findHitsByBlock = [:]; findAttachmentHits = [:]; findTextLayouts = [:]; findSnapshot = nil
        findBusy = !bar.query.stringValue.isEmpty; bar.canReplace = false; needsDisplay = true
        updateFindStatus()
        guard findBusy, (bar.query.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        // Wait before snapshotting the value document. No NSTextStorage work,
        // syntax parsing, or asset decoding happens on search keystrokes.
        findTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
            guard let self, findGeneration == generation, !hasMarkedText(), tableCellEditor?.hasMarkedText() != true else { return }
            let snapshot = content, query = bar.query.stringValue, sensitive = bar.caseButton.state == .on
            let worker = Task.detached(priority: .userInitiated) {
                NoteSearch.find(in: snapshot, query: query, caseSensitive: sensitive, cancelled: { Task.isCancelled })
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, findGeneration == generation else { return }
            findSnapshot = snapshot; findResult = result
            findHitsByBlock = Dictionary(grouping: result.hits, by: \.blockID)
            findAttachmentHits = findHitsByBlock.compactMapValues { hits in
                hits.first?.field == .text ? nil : Dictionary(grouping: hits, by: \.field)
            }
            findIndex = min(findIndex, max(0, result.hits.count - 1)); findBusy = false
            updateFindStatus(); needsDisplay = true
            if bar.query.currentEditor() != nil, result.hits.indices.contains(findIndex) { revealFindHit(result.hits[findIndex]) }
        }
    }

    func updateFindStatus() {
        guard let bar = findBar else { return }
        bar.refreshLanguage()
        let count = findResult.hits.count
        if findBusy { bar.status.stringValue = String(localized: "Searching…", bundle: bundle) }
        else if bar.query.stringValue.isEmpty { bar.status.stringValue = String(localized: "Text, code, tables, and image captions", bundle: bundle) }
        else if findResult.truncated { bar.status.stringValue = String(localized: "Too many matches. Refine your search to replace all.", bundle: bundle) }
        else if count == 0 { bar.status.stringValue = String(localized: "No matches", bundle: bundle) }
        else { bar.status.stringValue = "\(findIndex + 1) / \(count)" }
        bar.setSummary(bar.status.stringValue, count: count, index: findIndex, busy: findBusy, showMessage: findResult.truncated)
        bar.canReplaceAll = !findResult.truncated
        bar.canReplace = isEditable && !findBusy && count > 0 && !hasMarkedText() && tableCellEditor?.hasMarkedText() != true
    }

    func stepNoteSearch(_ direction: Int) {
        guard enclosingScrollView?.isFindBarVisible == true else { showNoteFind(replacing: false); return }
        guard !findBusy, !findResult.hits.isEmpty else { return }
        findIndex = (findIndex + direction + findResult.hits.count) % findResult.hits.count
        revealFindHit(findResult.hits[findIndex]); updateFindStatus(); needsDisplay = true
    }

    private func revealFindHit(_ hit: NoteSearch.Hit) {
        guard let span = spans.first(where: { $0.block.id == hit.blockID }) else { return }
        if hit.field == .text {
            scrollRangeToVisible(NSRange(location: span.textRange.location + hit.range.location, length: hit.range.length))
        } else {
            scrollRangeToVisible(span.textRange)
            if case .cell(let row, let column) = hit.field,
               let frame = tableFrame(blockID: hit.blockID) {
                let rect = tableLayout(for: span.block, width: frame.width).rect(row: row, column: column)
                scrollToVisible(rect.offsetBy(dx: frame.minX, dy: frame.minY))
            }
        }
    }

    func replaceNoteSearch(all: Bool) {
        guard let bar = findBar, !findBusy, isEditable, !hasMarkedText(), tableCellEditor?.hasMarkedText() != true,
              let snapshot = findSnapshot, snapshot == content, !findResult.hits.isEmpty,
              !all || !findResult.truncated,
              (bar.replacement.currentEditor() as? NSTextView)?.hasMarkedText() != true,
              (bar.query.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        endTableCellEditing(); endImageCaption(cancelled: false)
        guard snapshot == content else { scheduleNoteSearch(); return }
        let hits = all ? findResult.hits : [findResult.hits[findIndex]]
        let value = bar.replacement.stringValue, generation = findGeneration
        findBusy = true; updateFindStatus()
        findTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { NoteSearch.replacing(hits, in: snapshot, with: value, cancelled: { Task.isCancelled }) }
            let next = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, findGeneration == generation else { return }
            guard content == snapshot, isEditable, !hasMarkedText(), tableCellEditor?.hasMarkedText() != true else { scheduleNoteSearch(); return }
            guard let next, (try? next.validate()) != nil else {
                findBusy = false; updateFindStatus()
                bar.showError(String(localized: "Cannot replace this text. Shorten the replacement and try again.", bundle: bundle))
                return
            }
            guard next != content else { findBusy = false; updateFindStatus(); return }
            let index = next.blocks.firstIndex(where: { $0.id == hits[0].blockID }) ?? 0
            let offset = hits[0].field == .text ? hits[0].range.location : 0
            replaceDocument(next, block: index, offset: offset)
            findHistoryTargetsNote = true
            undoManager?.setActionName(all ? String(localized: "Replace All", bundle: bundle) : String(localized: "Replace", bundle: bundle))
        }
    }

    /// After replacing from the find bar, Command-Z undoes the note transaction.
    /// Editing either draft returns undo ownership to the native field editor.
    func handleFindHistory(_ event: NSEvent) -> Bool {
        guard findHistoryTargetsNote, enclosingScrollView?.isFindBarVisible == true,
              let bar = findBar, let responder = window?.firstResponder as? NSTextView,
              responder === bar.query.currentEditor() || responder === bar.replacement.currentEditor(),
              !responder.hasMarkedText(), !hasMarkedText(), isEditable else { return false }
        let flags = event.modifierFlags.intersection(ShortcutBinding.allowedModifiers)
        guard event.keyCode == 6, flags == .command || flags == [.command, .shift] else { return false }
        if !event.isARepeat {
            if flags.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }
        }
        return true
    }

    private func drawNoteSearch(in dirtyRect: NSRect) {
        guard !findBusy, !findHitsByBlock.isEmpty, enclosingScrollView?.isFindBarVisible == true,
              let manager = textLayoutManager, let source = manager.textContentManager else { return }
        let origin = textContainerOrigin
        let viewport = manager.textViewportLayoutController.viewportRange
        let low = viewport.map { source.offset(from: source.documentRange.location, to: $0.location) } ?? 0
        let high = viewport.map { source.offset(from: source.documentRange.location, to: $0.endLocation) } ?? (string as NSString).length
        let active = findResult.hits.indices.contains(findIndex) ? findResult.hits[findIndex] : nil
        func paint(_ rect: NSRect, hit: NoteSearch.Hit) {
            guard rect.intersects(dirtyRect) else { return }
            let selected = hit == active
            (selected ? NSColor.systemOrange : NSColor.systemYellow).withAlphaComponent(selected ? 0.40 : 0.27).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            if selected { NSColor.systemOrange.setStroke(); NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke() }
        }
        for span in spans where NSMaxRange(span.textRange) >= low && span.textRange.location <= high {
            guard let hits = findHitsByBlock[span.block.id] else { continue }
            if !span.block.kind.isAttachment {
                // Binary search skips offscreen matches in a very large block.
                var left = 0, right = hits.count
                while left < right {
                    let mid = (left + right) / 2
                    if NSMaxRange(hits[mid].range) + span.textRange.location < low { left = mid + 1 } else { right = mid }
                }
                for hit in hits[left...] {
                    let startOffset = span.textRange.location + hit.range.location
                    if startOffset > high { break }
                    guard let start = source.location(source.documentRange.location, offsetBy: max(low, startOffset)),
                          let end = source.location(source.documentRange.location, offsetBy: min(high, startOffset + hit.range.length)),
                          let range = NSTextRange(location: start, end: end) else { continue }
                    manager.enumerateTextSegments(in: range, type: .selection, options: .rangeNotRequired) { _, rect, _, _ in
                        paint(rect.offsetBy(dx: origin.x, dy: origin.y), hit: hit); return true
                    }
                }
            } else if let frame = (span.block.table != nil ? tableFrame(blockID: span.block.id) : imageFrame(blockID: span.block.id)), frame.intersects(dirtyRect) {
                for (field, matches) in findAttachmentHits[span.block.id] ?? [:] {
                    let rect: NSRect, text: String, font: NSFont
                    switch field {
                    case .cell(let row, let column):
                        let layout = tableLayout(for: span.block, width: frame.width)
                        rect = layout.rect(row: row, column: column).insetBy(dx: TableBlockLayout.padding, dy: TableBlockLayout.padding).offsetBy(dx: frame.minX, dy: frame.minY)
                        text = layout.table.rows[row][column]
                        font = layout.table.isHeader(row: row, column: column) ? TableBlockLayout.headerFont : TableBlockLayout.font
                    case .caption:
                        rect = NSRect(x: frame.minX, y: frame.maxY - 22, width: frame.width, height: 22)
                        text = span.block.image?.caption ?? ""; font = .systemFont(ofSize: 12)
                    case .text: continue
                    }
                    guard rect.intersects(dirtyRect) else { continue }
                    // Only visible attachment text is laid out; no asset decoding.
                    let key = FindFieldKey(block: span.block.id, field: field)
                    if findTextLayouts[key]?.container.size != rect.size {
                        if findTextLayouts.count >= 64 { findTextLayouts.removeAll(keepingCapacity: true) }
                        let storage = NSTextStorage(string: text, attributes: [.font: font])
                        let layout = NSLayoutManager(), container = NSTextContainer(size: rect.size)
                        container.lineFragmentPadding = 0
                        if field == .caption { container.maximumNumberOfLines = 1; container.lineBreakMode = .byTruncatingTail }
                        storage.addLayoutManager(layout); layout.addTextContainer(container)
                        findTextLayouts[key] = FindTextLayout(storage: storage, manager: layout, container: container)
                    }
                    guard let cached = findTextLayouts[key] else { continue }
                    let layout = cached.manager, container = cached.container
                    let clip = rect.intersection(visibleRect).offsetBy(dx: -rect.minX, dy: -rect.minY)
                    let visibleGlyphs = layout.glyphRange(forBoundingRect: clip, in: container)
                    let visibleCharacters = layout.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
                    var lo = 0, hi = matches.count
                    while lo < hi {
                        let mid = (lo + hi) / 2
                        if NSMaxRange(matches[mid].range) < visibleCharacters.location { lo = mid + 1 } else { hi = mid }
                    }
                    for hit in matches[lo...] {
                        if hit.range.location > NSMaxRange(visibleCharacters) { break }
                        let glyphs = layout.glyphRange(forCharacterRange: hit.range, actualCharacterRange: nil)
                        layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { box, _ in
                            paint(box.offsetBy(dx: rect.minX, dy: rect.minY).intersection(rect), hit: hit)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Explicit Markdown image imports, at most three downloads per editor.
extension PaperTextView {
    func enqueueRemoteImages(_ ids: [UUID]) {
        guard isEditable, !hasMarkedText(), file != nil else { return }
        for id in ids.prefix(32) where remoteImageTasks[id] == nil && !remoteImageQueue.contains(id) {
            remoteImageQueue.append(id)
        }
        startRemoteImageQueue()
    }
    private func reconcileRemoteImages() {
        guard !remoteImageTasks.isEmpty else { return }
        for (id, entry) in remoteImageTasks {
            if !content.blocks.contains(where: { $0.id == id && $0.image?.id == entry.image && $0.image?.remoteSource == entry.source && $0.image?.isRemotePlaceholder == true }) {
                entry.task.cancel(); remoteImageTasks.removeValue(forKey: id)
            }
        }
    }
    private func startRemoteImageQueue() {
        guard let file, isEditable else { return }
        while remoteImageTasks.count < 3, !remoteImageQueue.isEmpty {
            let id = remoteImageQueue.removeFirst()
            guard let image = content.blocks.first(where: { $0.id == id })?.image, image.isRemotePlaceholder,
                  let source = image.remoteSource, let url = RemoteImageReference.downloadURL(source) else { continue }
            let fetch = fetchRemoteImage, directory = file.assetsURL, token = UUID()
            let task = Task { [weak self] in
                defer {
                    if self?.remoteImageTasks[id]?.token == token { self?.remoteImageTasks.removeValue(forKey: id) }
                    self?.startRemoteImageQueue()
                }
                let result: NoteImage?
                do {
                    let bytes = try await fetch(url)
                    try Task.checkCancellation()
                    result = try await RemoteImageImporter.prepare(bytes, name: image.name, directory: directory)
                } catch is CancellationError { return }
                catch { result = nil }
                guard !Task.isCancelled else { return }
                // Composition owns the editor until committed. Do not replace
                // its storage while a network request happens to finish.
                while self?.hasMarkedText() == true || self?.tableCellEditor?.hasMarkedText() == true || self?.imageCaptionBlock != nil || self?.imageResize != nil {
                    do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                }
                guard let self, !Task.isCancelled, isEditable,
                      let index = content.blocks.firstIndex(where: { $0.id == id }),
                      var current = content.blocks[index].image,
                      current.id == image.id, current.remoteSource == source, current.isRemotePlaceholder else { return }
                if let result {
                    current.id = result.id; current.pixelWidth = result.pixelWidth; current.pixelHeight = result.pixelHeight
                    current.isSVG = result.isSVG; current.remoteState = nil
                    current.displayWidth = current.displayWidth ?? result.displayWidth
                } else { current.remoteState = .failed }
                var next = content; next.blocks[index].image = current
                guard next != content else { return }
                replaceDocument(next, block: index, preservingSelection: true)
                undoManager?.setActionName(String(localized: "Load remote image", bundle: bundle))
                _ = onRemoteImageCommit?()
            }
            remoteImageTasks[id] = (token, image.id, source, task)
        }
    }
}


// MARK: - Ordinary file attachments
extension PaperTextView {
    private func attachmentURLs(from board: NSPasteboard) -> [URL]? {
        guard let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return nil }
        if urls.count == 1, let url = urls.first {
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            if type?.conforms(to: .image) == true || NoteVideo.extensions.contains(url.pathExtension.lowercased()) || NoteAudio.extensions.contains(url.pathExtension.lowercased()) { return nil }
        }
        return urls
    }
    @discardableResult func importAttachments(from board: NSPasteboard) -> Bool {
        guard let urls = attachmentURLs(from: board) else { return false }
        guard let source = activeSpan?.block else { return true }
        importAttachments(urls: urls, source: source)
        return true
    }
    @objc func chooseAttachments(_ sender: Any?) {
        guard file?.libraryPath?.writable != false, !importInProgress, isEditable, !hasMarkedText(), tableCellEditor == nil,
              let source = activeSpan?.block, let window else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.treatsFilePackagesAsDirectories = true
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK else { return }
            self?.importAttachments(urls: panel.urls, source: source)
        }
    }
    func importAttachments(urls: [URL], source: NoteBlock) {
        guard file?.libraryPath?.writable != false, !importInProgress, let file, isEditable, !hasMarkedText(), tableCellEditor == nil else { return }
        importInProgress = true
        onStatusChange?(.importingAttachment)
        let directory = file.assetsURL.appendingPathComponent("files", isDirectory: true)
        Task { [weak self] in
            do {
                let attachments = try await Task.detached(priority: .userInitiated) {
                    try NoteAttachmentImporter.prepare(urls: urls, directory: directory)
                }.value
                guard let self else { NoteAttachmentImporter.removeUninserted(attachments, directory: directory); return }
                importInProgress = false
                onStatusChange?(nil)
                guard insertAttachments(attachments, source: source) else {
                    NoteAttachmentImporter.removeUninserted(attachments, directory: directory)
                    attachmentError(String(localized: "The insertion block changed. Paste the attachments again.", bundle: bundle)); return
                }
                if onAttachmentCommit?() == false {
                    attachmentError(String(localized: "The attachments could not be saved. Their files are kept; retry saving the note.", bundle: bundle))
                }
            } catch {
                guard let self else { return }
                importInProgress = false
                onStatusChange?(nil)
                attachmentError(String(localized: "Could not import attachments. Choose up to 32 ordinary files totaling no more than 512 MB. Folders and app packages are not supported.", bundle: bundle))
            }
        }
    }
    @discardableResult func insertAttachments(_ attachments: [NoteAttachment], source: NoteBlock) -> Bool {
        guard !attachments.isEmpty, attachments.allSatisfy(\.isValid), isEditable, !hasMarkedText(), tableCellEditor == nil,
              let file, attachments.allSatisfy({ FileManager.default.fileExists(atPath: file.attachmentURL($0).path) }),
              let index = content.blocks.firstIndex(of: source) else { return false }
        var next = content
        let blocks = attachments.map { NoteBlock(kind: .file, attachment: $0) }
        let destination = source.text.isEmpty && !source.kind.isAttachment ? index : index + 1
        if destination == index { next.blocks.replaceSubrange(index...index, with: blocks) }
        else { next.blocks.insert(contentsOf: blocks, at: destination) }
        let after = destination + blocks.count
        if after == next.blocks.count { next.blocks.append(NoteBlock()) }
        replaceDocument(next, block: after)
        undoManager?.setActionName(String(localized: "Import Attachments…", bundle: bundle))
        return true
    }
    @discardableResult func openAttachment(blockID: UUID) -> Bool {
        guard !hasMarkedText(), let file, let attachment = content.blocks.first(where: { $0.id == blockID })?.attachment else { return false }
        let url = file.attachmentURL(attachment)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, NSWorkspace.shared.open(url) else {
            attachmentError(String(localized: "The attachment could not be opened. Its file may be missing or no app is available.", bundle: bundle)); return false
        }
        return true
    }
    private func attachmentError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = String(localized: "Attachment", bundle: bundle)
        alert.informativeText = message; alert.beginSheetModal(for: window)
    }
}
