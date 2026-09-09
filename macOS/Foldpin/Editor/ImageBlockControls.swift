import AppKit

@MainActor
final class ImageBlockControls: NSView, NSTextFieldDelegate {
    weak var editor: PaperTextView?
    var blockID: UUID?
    let leftGrip = ImageResizeGrip()
    let rightGrip = ImageResizeGrip()
    let captionButton = ImageToolbarButton()
    let resetButton = ImageToolbarButton()
    let moreButton = ImageToolbarButton()
    let captionField = NSTextField()
    let toolbar = ImageToolbarSurface()
    private var tipTask: DispatchWorkItem?
    private var tipPanel: NSPanel?
    override var isHidden: Bool { didSet {
        if isHidden {
            hideTip()
            for button in [captionButton, resetButton, moreButton] { button.clearHover() }
        }
    } }
    private var tracking: NSTrackingArea?
    var editingCaption = false
    var isPresentingMenu = false
    var isResizing: Bool { leftGrip.trackingDrag || rightGrip.trackingDrag }
    override var isFlipped: Bool { true }

    init(editor: PaperTextView) {
        self.editor = editor
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        addSubview(toolbar)
        for (button, icon, selector) in [(captionButton, "text.below.photo", #selector(editCaption)),
                                         (resetButton, "arrow.up.left.and.arrow.down.right", #selector(resetSize)),
                                         (moreButton, "ellipsis", #selector(more))] {
            button.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            button.isBordered = false; button.bezelStyle = .inline
            button.target = self; button.action = selector
            button.imageScaling = .scaleProportionallyDown
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            button.onHover = { [weak self, weak button] entered in
                guard let self else { return }
                hideTip()
                guard entered, let button else { return }
                let task = DispatchWorkItem { [weak self, weak button] in
                    guard let self, let button else { return }
                    self.showTip(for: button)
                }
                tipTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
            }
            button.onPress = { [weak self] in self?.hideTip() }
            toolbar.addSubview(button)
        }
        for (grip, side) in [(leftGrip, -1.0), (rightGrip, 1.0)] {
            grip.resizeDirection = side
            grip.onBegin = { [weak self] in
                guard let self, let id = blockID else { return false }
                return self.editor?.beginImageResize(blockID: id, side: side) ?? false
            }
            grip.onDrag = { [weak self] delta in self?.editor?.previewImageResize(delta: delta) }
            grip.onEnd = { [weak self] cancelled in self?.editor?.endImageResize(cancelled: cancelled) }
            addSubview(grip)
        }
        captionField.font = .systemFont(ofSize: 12)
        captionField.isBordered = false; captionField.drawsBackground = true
        captionField.focusRingType = .none; captionField.delegate = self
        captionField.isHidden = true
        addSubview(captionField)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        return subviews.contains { !$0.isHidden && $0.frame.contains(local) } ? super.hitTest(point) : nil
    }
    func containsControls(_ point: NSPoint) -> Bool {
        let local = convert(point, from: editor)
        return !isHidden && subviews.contains { !$0.isHidden && $0.frame.insetBy(dx: -2, dy: -2).contains(local) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard tracking == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseMoved(with event: NSEvent) { editor?.updateImageControls(at: editor?.convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { mouseMoved(with: event) }
    func update(image: NoteImage, frame imageFrame: NSRect, viewport: NSRect, ink: NSColor, background: NSColor, bundle: Bundle) {
        let rect = convert(imageFrame, from: editor)
        let visible = convert(viewport, from: editor)
        let imageHeight = ImageBlockLayout(image: image, availableWidth: rect.width).imageSize.height
        let imageRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: imageHeight)
        let barHeight = min(40, max(18, imageRect.height - 8))
        for (grip, x) in [(leftGrip, imageRect.minX), (rightGrip, imageRect.maxX - 12)] {
            grip.frame = NSRect(x: x, y: imageRect.midY - barHeight / 2, width: 12, height: barHeight)
            grip.isHidden = editingCaption || !visible.contains(grip.frame)
            grip.setAccessibilityLabel(String(localized: "Resize image", bundle: bundle))
            grip.setAccessibilityElement(true)
            grip.setAccessibilityRole(.slider)
            grip.setAccessibilityValue(Int(imageRect.width))
        }
        let toolbarFrame = NSRect(x: imageRect.maxX - 104, y: imageRect.minY + 6, width: 98, height: 36)
        if toolbar.frame != toolbarFrame { hideTip(); toolbar.frame = toolbarFrame }
        toolbar.isHidden = editingCaption || imageRect.width < 110 || !visible.contains(toolbarFrame)
        if toolbar.isHidden { hideTip() }
        toolbar.ink = ink; toolbar.fill = background
        for (i, button, title) in [(0, captionButton, String(localized: "Edit image caption", bundle: bundle)),
                                  (1, resetButton, String(localized: "Reset image size", bundle: bundle)),
                                  (2, moreButton, String(localized: "Image actions", bundle: bundle))] {
            button.frame = NSRect(x: 4 + CGFloat(i) * 30, y: 4, width: 30, height: 28)
            button.contentTintColor = ink
            button.ink = ink
            button.hint = title
            button.setAccessibilityLabel(title)
            button.setAccessibilityHelp(title)
        }
        if editingCaption {
            captionField.frame = NSRect(x: rect.minX, y: imageRect.maxY + 6, width: rect.width, height: 22)
            captionField.textColor = NotePalette.secondaryText(for: ink)
            captionField.backgroundColor = background
            captionField.placeholderString = String(localized: "Image caption", bundle: bundle)
            captionField.setAccessibilityLabel(String(localized: "Image caption", bundle: bundle))
        }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { hideTip() }
        super.viewWillMove(toWindow: newWindow)
    }
    private func hideTip() {
        tipTask?.cancel(); tipTask = nil
        if let tipPanel { tipPanel.parent?.removeChildWindow(tipPanel); tipPanel.orderOut(nil) }
        tipPanel = nil
    }
    private func showTip(for button: ImageToolbarButton) {
        guard !isHiddenOrHasHiddenAncestor, !toolbar.isHidden, !isPresentingMenu, let window,
              button.convert(button.bounds, to: nil).contains(window.mouseLocationOutsideOfEventStream) else { return }
        let label = NSTextField(labelWithString: button.hint)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 20, height: 30)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        let surface = NSView(frame: NSRect(origin: .zero, size: size))
        surface.wantsLayer = true; surface.layer?.cornerRadius = 7
        surface.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 0.98).cgColor
        label.frame.origin = NSPoint(x: 10, y: (size.height - label.frame.height) / 2)
        surface.addSubview(label); panel.contentView = surface
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? anchor.insetBy(dx: -500, dy: -500)
        let x = min(max(anchor.midX - size.width / 2, screen.minX + 4), screen.maxX - size.width - 4)
        let y = anchor.maxY + size.height + 8 <= screen.maxY ? anchor.maxY + 8 : anchor.minY - size.height - 8
        panel.setFrameOrigin(NSPoint(x: x, y: max(screen.minY + 4, y)))
        tipPanel = panel
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }
    @objc private func editCaption() { hideTip(); if let blockID { editor?.beginImageCaption(blockID: blockID) } }
    @objc private func resetSize() { hideTip(); if let blockID { editor?.resetImageSize(blockID: blockID) } }
    @objc private func more() {
        hideTip()
        guard let blockID, let menu = editor?.makeBlockActionMenu(blockID: blockID) else { return }
        isPresentingMenu = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.maxY), in: moreButton)
        isPresentingMenu = false
    }
    isolated deinit {
        tipTask?.cancel()
        if let tipPanel { tipPanel.parent?.removeChildWindow(tipPanel); tipPanel.orderOut(nil) }
    }
    func controlTextDidEndEditing(_ obj: Notification) { if editingCaption { editor?.endImageCaption(cancelled: false) } }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            editor?.endImageCaption(cancelled: true); return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.insertTab(_:)) {
            editor?.endImageCaption(cancelled: false); return true
        }
        return false
    }
}

@MainActor
final class ImageResizeGrip: NSView {
    var resizeDirection: CGFloat = 1
    var onBegin: (() -> Bool)?
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: ((Bool) -> Void)?
    private(set) var trackingDrag = false
    private var startX: CGFloat = 0
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {
        guard onBegin?() == true else { return }
        trackingDrag = true; startX = NSEvent.mouseLocation.x
        window?.makeFirstResponder(self)
    }
    override func mouseDragged(with event: NSEvent) { if trackingDrag { onDrag?(NSEvent.mouseLocation.x - startX) } }
    override func mouseUp(with event: NSEvent) { if trackingDrag { trackingDrag = false; onEnd?(false) } }
    override func cancelOperation(_ sender: Any?) { trackingDrag = false; onEnd?(true) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil); return }
        if event.keyCode == 123 || event.keyCode == 124 {
            guard onBegin?() == true else { return }
            onDrag?(event.keyCode == 123 ? -5 : 5); onEnd?(false)
        } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformIncrement() -> Bool { resizeAccessibly(5) }
    override func accessibilityPerformDecrement() -> Bool { resizeAccessibly(-5) }
    private func resizeAccessibly(_ delta: CGFloat) -> Bool {
        guard onBegin?() == true else { return false }
        onDrag?(delta * resizeDirection); onEnd?(false); return true
    }
    func cancelTracking() { trackingDrag = false }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 3, dy: 0)
        NSColor.black.withAlphaComponent(0.45).setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3); path.fill()
        NSColor.white.withAlphaComponent(0.85).setStroke(); path.lineWidth = 1; path.stroke()
    }
}


@MainActor
final class ImageToolbarSurface: NSView {
    override var isHidden: Bool { didSet {
        if isHidden { for case let button as ImageToolbarButton in subviews { button.clearHover() } }
    } }
    var ink: NSColor = .labelColor { didSet { if ink != oldValue { needsDisplay = true } } }
    var fill: NSColor = .windowBackgroundColor { didSet { if fill != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        fill.withAlphaComponent(0.98).setFill(); path.fill()
        ink.withAlphaComponent(0.12).setStroke(); path.lineWidth = 0.5; path.stroke()
    }
}

@MainActor
final class ImageToolbarButton: NSButton {
    var ink: NSColor = .labelColor { didSet { if ink != oldValue { needsDisplay = true } } }
    var hint = ""
    var onHover: ((Bool) -> Void)?
    var onPress: (() -> Void)?
    private var hovered = false
    private var pointerArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard pointerArea == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); pointerArea = area
    }
    func clearHover() { if hovered { hovered = false; needsDisplay = true } }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true; onHover?(false) }
    override func mouseDown(with event: NSEvent) { onPress?(); super.mouseDown(with: event) }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted {
            ink.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 0), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
}
