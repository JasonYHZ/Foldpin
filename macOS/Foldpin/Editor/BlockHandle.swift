import AppKit

enum BlockAction: Equatable {
    case convert(NoteBlockKind), copy, copyImage, duplicate, moveUp, moveDown, delete, addTableRow, addTableColumn, toggleHeaderRow, toggleHeaderColumn
    case insertTableRow(Int), insertTableColumn(Int), deleteTableRow(Int), deleteTableColumn(Int)
    case imageCaption, resetImageSize, removeImageCaption, exportMedia
    case copyCode, codeLanguage(CodeLanguage), toggleTask
}

struct BlockMenuCommand {
    let blockID: UUID
    let action: BlockAction
}

/// A single reusable gutter control, outside the scrolling clip view.
@MainActor
final class BlockHandleButton: NSButton, NSDraggingSource {
    var ink: NSColor = .labelColor {
        didSet { if ink != oldValue { needsDisplay = true } }
    }
    var blockID: UUID?
    var onOpen: ((UUID, BlockHandleButton) -> Void)?
    var onMenuFinished: (() -> Void)?
    var onPointerChange: ((NSPoint) -> Void)?
    var onPrepareDrag: ((UUID) -> BlockDragPreview?)?
    var onDragFinished: (() -> Void)?
    private var pressedBlockID: UUID?
    private var pressLocation: NSPoint?
    private var exceededDragThreshold = false
    private(set) var isDraggingBlock = false
    var isTrackingPointer: Bool { pressLocation != nil || isDraggingBlock }
    private(set) var isPresentingMenu = false
    private var pointerTrackingArea: NSTrackingArea?
    private var hovered = false
    private var languageBundle: Bundle?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 26))
        isBordered = false
        refusesFirstResponder = true
        focusRingType = .none
        setButtonType(.momentaryChange)
        target = self
        action = #selector(openActions(_:))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func updateLanguage(bundle: Bundle) {
        guard languageBundle !== bundle else { return }
        languageBundle = bundle
        let label = String(localized: "Block actions", bundle: bundle)
        toolTip = String(localized: "Click for actions; drag to reorder.", bundle: bundle)
        setAccessibilityLabel(label)
        setAccessibilityHelp(String(localized: "Click for actions; drag to reorder.", bundle: bundle))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard pointerTrackingArea == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true; needsDisplay = true
        onPointerChange?(event.locationInWindow)
    }
    override func mouseMoved(with event: NSEvent) { onPointerChange?(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) {
        hovered = false; needsDisplay = true
        onPointerChange?(event.locationInWindow)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let blockID else { return }
        pressedBlockID = blockID
        pressLocation = event.locationInWindow
        exceededDragThreshold = false
        isHighlighted = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDraggingBlock, !exceededDragThreshold, let origin = pressLocation, let id = pressedBlockID,
              hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 5 else { return }
        exceededDragThreshold = true
        guard let preview = onPrepareDrag?(id) else { return }
        let item = NSPasteboardItem()
        item.setString(preview.token.uuidString, forType: BlockReordering.pasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let point = convert(event.locationInWindow, from: nil)
        draggingItem.setDraggingFrame(NSRect(x: point.x + 10, y: point.y - 18,
                                            width: preview.image.size.width, height: preview.image.size.height), contents: preview.image)
        isDraggingBlock = true
        isHighlighted = false
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        let openMenu = !isDraggingBlock && !exceededDragThreshold && pressedBlockID == blockID &&
            bounds.contains(convert(event.locationInWindow, from: nil))
        pressLocation = nil
        pressedBlockID = nil
        isHighlighted = false
        if openMenu { performClick(nil) }
        if !isDraggingBlock { onMenuFinished?() }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDraggingBlock = false
        pressLocation = nil
        pressedBlockID = nil
        exceededDragThreshold = false
        isHighlighted = false
        onDragFinished?()
    }

    @objc private func openActions(_ sender: Any?) {
        guard let blockID else { return }
        isPresentingMenu = true
        defer { isPresentingMenu = false; onMenuFinished?() }
        onOpen?(blockID, self)
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted {
            ink.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        NotePalette.secondaryText(for: ink).setFill()
        for x in [-2.5, 2.5] {
            for y in [-5.0, 0, 5] {
                NSBezierPath(ovalIn: NSRect(x: bounds.midX + x - 1.25, y: bounds.midY + y - 1.25, width: 2.5, height: 2.5)).fill()
            }
        }
    }
}
