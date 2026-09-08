import AppKit

/// Two reusable overlay buttons. The rest of this view passes all events through.
@MainActor
final class TableAddControls: NSView {
    var blockID: UUID?
    var onAdd: ((UUID, Bool) -> Void)?
    var onPointerChange: ((NSPoint) -> Void)?
    let rowButton = TableAddButton()
    let columnButton = TableAddButton()
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        for button in [rowButton, columnButton] {
            button.target = self
            button.action = #selector(add(_:))
            button.onPointerChange = { [weak self] in self?.onPointerChange?($0) }
            addSubview(button)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateColors(_ ink: NSColor) {
        for button in [rowButton, columnButton] where button.ink != ink { button.ink = ink }
    }

    func containsControl(at point: NSPoint) -> Bool {
        !isHidden && [rowButton, columnButton].contains { !$0.isHidden && $0.frame.contains(point) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        containsControl(at: convert(point, from: superview)) ? super.hitTest(point) : nil
    }

    func update(grid: NSRect, viewport: NSRect, editor: NSView, bundle: Bundle, enabled: Bool) {
        let row = NSRect(x: grid.minX, y: grid.maxY + 3, width: grid.width, height: 18)
        let column = NSRect(x: grid.maxX + 4, y: max(grid.minY, viewport.minY), width: 18,
                            height: max(0, min(grid.maxY, viewport.maxY) - max(grid.minY, viewport.minY)))
        rowButton.isHidden = !viewport.contains(row)
        columnButton.isHidden = column.height < 20 || !viewport.contains(column)
        for (button, rect, label) in [(rowButton, row, String(localized: "Add Row", bundle: bundle)),
                                      (columnButton, column, String(localized: "Add Column", bundle: bundle))] {
            let frame = backingAlignedRect(convert(rect, from: editor), options: .alignAllEdgesNearest)
            if button.frame != frame { button.frame = frame }
            button.isEnabled = enabled
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
        isHidden = rowButton.isHidden && columnButton.isHidden
    }

    @objc private func add(_ sender: NSButton) {
        guard let blockID else { return }
        onAdd?(blockID, sender === rowButton)
    }
}

@MainActor
final class TableAddButton: NSButton {
    var ink: NSColor = .labelColor {
        didSet {
            contentTintColor = NotePalette.secondaryText(for: ink)
            needsDisplay = true
        }
    }
    var onPointerChange: ((NSPoint) -> Void)?
    private var hovered = false
    private var pointerArea: NSTrackingArea?
    init() {
        super.init(frame: .zero)
        isBordered = false
        refusesFirstResponder = true
        focusRingType = .none
        image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        contentTintColor = .secondaryLabelColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard pointerArea == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); pointerArea = area
    }
    override func mouseEntered(with event: NSEvent) {
        hovered = true; needsDisplay = true; onPointerChange?(event.locationInWindow)
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false; needsDisplay = true; onPointerChange?(event.locationInWindow)
    }
    override func draw(_ dirtyRect: NSRect) {
        ink.withAlphaComponent(hovered || isHighlighted ? 0.12 : 0.045).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).fill()
        super.draw(dirtyRect)
    }
}
