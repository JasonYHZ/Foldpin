import AppKit

@MainActor
final class NoteFindBar: NSView, NSSearchFieldDelegate {
    let query = NSSearchField()
    let replacement = NSTextField()
    let status = NSTextField(labelWithString: "0/0")
    let caseButton = FindToolButton(title: "Aa", target: nil, action: nil)
    private let disclosure = FindToolButton(), previous = FindToolButton(), next = FindToolButton(), close = FindToolButton()
    private let replace = FindToolButton(), replaceAll = FindToolButton()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let panelContent = FindPanelContent()
    private lazy var glassSurface = EditorGlassSurface(content: panelContent, cornerRadius: 17)
    private var hasMessage = false
    var onQuery: (() -> Void)?
    var onDraftEdit: (() -> Void)?
    var onStep: ((Int) -> Void)?
    var onReplace: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    var canReplace = false { didSet { replace.isEnabled = canReplace; replaceAll.isEnabled = canReplace && canReplaceAll } }
    var canReplaceAll = true { didSet { replaceAll.isEnabled = canReplace && canReplaceAll } }
    var replacing = false { didSet { updateHeight(); refreshDisclosure() } }
    override var isFlipped: Bool { true }
    private var panelRect: NSRect { NSRect(x: 8, y: 6, width: max(0, bounds.width - 16), height: replacing ? 80 : 42) }

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 54))
        addSubview(glassSurface)
        query.delegate = self; replacement.delegate = self
        query.sendsSearchStringImmediately = true; query.sendsWholeSearchString = false
        for field in [query as NSTextField, replacement] {
            field.font = .systemFont(ofSize: 13)
            field.isBordered = false; field.isBezeled = false; field.drawsBackground = false
            field.focusRingType = .none
            panelContent.addSubview(field)
        }
        (query.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        (query.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        status.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        status.textColor = .secondaryLabelColor; status.alignment = .right
        status.lineBreakMode = .byTruncatingTail
        message.font = .systemFont(ofSize: 11); message.textColor = .secondaryLabelColor
        panelContent.addSubview(status); addSubview(message)
        for (button, symbol, action) in [
            (disclosure, "chevron.right", #selector(toggleReplacement)),
            (previous, "arrow.left.circle.fill", #selector(back)), (next, "arrow.right.circle.fill", #selector(forward)),
            (close, "xmark.circle.fill", #selector(dismiss)),
            (replaceAll, "arrow.trianglehead.2.clockwise.rotate.90", #selector(replaceEvery)),
            (replace, "return", #selector(replaceOne))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            button.target = self; button.action = action; panelContent.addSubview(button)
        }
        caseButton.imagePosition = .noImage
        caseButton.font = .systemFont(ofSize: 10, weight: .medium)
        caseButton.target = self; caseButton.action = #selector(changed)
        caseButton.setButtonType(.pushOnPushOff); panelContent.addSubview(caseButton)
        refreshLanguage(); updateHeight()
    }
    required init?(coder: NSCoder) { nil }
    private func updateHeight() {
        replacement.isHidden = !replacing; replace.isHidden = !replacing; replaceAll.isHidden = !replacing
        message.isHidden = !hasMessage
        setFrameSize(NSSize(width: frame.width, height: (replacing ? 92 : 54) + (hasMessage ? 36 : 0)))
        needsLayout = true; needsDisplay = true
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView { scroll.findBarViewDidChangeHeight(); break }
            ancestor = view.superview
        }
    }
    override func layout() {
        super.layout()
        glassSurface.frame = panelRect
        glassSurface.layoutSubtreeIfNeeded()
        panelContent.replacing = replacing
        let panel = panelContent.bounds, y = panel.minY + 8
        close.frame = NSRect(x: panel.maxX - 34, y: y, width: 26, height: 26)
        next.frame = close.frame.offsetBy(dx: -33, dy: 0)
        previous.frame = next.frame.offsetBy(dx: -25, dy: 0)
        let countWidth = min(68, max(27, status.intrinsicContentSize.width + 1))
        status.frame = NSRect(x: previous.frame.minX - countWidth - 4, y: y + 5, width: countWidth, height: 17)
        caseButton.frame = NSRect(x: status.frame.minX - 27, y: y, width: 23, height: 26)
        disclosure.frame = NSRect(x: panel.minX + 8, y: y, width: 23, height: 26)
        query.frame = NSRect(x: disclosure.frame.maxX + 3, y: y + 4, width: max(20, caseButton.frame.minX - disclosure.frame.maxX - 8), height: 21)
        replacement.frame = NSRect(x: query.frame.minX, y: panel.minY + 51, width: max(20, panel.width - 108), height: 21)
        replace.frame = NSRect(x: close.frame.minX, y: panel.minY + 46, width: 26, height: 26)
        replaceAll.frame = replace.frame.offsetBy(dx: -28, dy: 0)
        message.frame = NSRect(x: panelRect.minX + 8, y: panelRect.maxY + 4, width: panel.width - 16, height: 30)
    }
    func setSummary(_ text: String, count: Int, index: Int, busy: Bool, showMessage: Bool = false) {
        status.stringValue = busy ? "…" : "\(count == 0 ? 0 : index + 1)/\(count)"
        status.toolTip = text; status.setAccessibilityLabel(text)
        previous.isEnabled = !busy && count > 0; next.isEnabled = !busy && count > 0
        message.stringValue = text
        if hasMessage != showMessage { hasMessage = showMessage; updateHeight() }
        needsLayout = true
    }
    func showError(_ text: String) {
        message.stringValue = text; hasMessage = true; updateHeight()
    }
    private func refreshDisclosure() {
        disclosure.image = NSImage(systemSymbolName: replacing ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        let bundle = LanguageSettings.shared.bundle
        let label = replacing ? String(localized: "Hide Replace", bundle: bundle) : String(localized: "Show Replace", bundle: bundle)
        disclosure.toolTip = label; disclosure.setAccessibilityLabel(label)
    }
    func refreshLanguage() {
        let bundle = LanguageSettings.shared.bundle
        query.placeholderString = String(localized: "Find", bundle: bundle)
        query.setAccessibilityLabel(String(localized: "Find in Note", bundle: bundle))
        replacement.placeholderString = String(localized: "Replace", bundle: bundle)
        replacement.setAccessibilityLabel(String(localized: "Replace with", bundle: bundle))
        for field in [query as NSTextField, replacement] {
            field.placeholderAttributedString = NSAttributedString(string: field.placeholderString ?? "", attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor
            ])
        }
        for (button, label) in [(previous, String(localized: "Previous Match", bundle: bundle)), (next, String(localized: "Next Match", bundle: bundle)), (close, String(localized: "Close Find", bundle: bundle)), (caseButton, String(localized: "Match Case", bundle: bundle)), (replace, String(localized: "Replace", bundle: bundle)), (replaceAll, String(localized: "Replace All", bundle: bundle))] {
            button.toolTip = label; button.setAccessibilityLabel(label)
        }
        refreshDisclosure()
    }
    func controlTextDidChange(_ notification: Notification) {
        onDraftEdit?()
        guard notification.object as? NSSearchField === query else { return }
        onQuery?()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { onClose?(); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { onStep?(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1); return true }
        return false
    }
    @objc func toggleReplacement() {
        guard (replacement.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if replacing, replacement.currentEditor() != nil { window?.makeFirstResponder(query) }
        replacing.toggle()
    }
    @objc private func changed() { onQuery?() }
    @objc private func back() { onStep?(-1) }
    @objc private func forward() { onStep?(1) }
    @objc private func dismiss() { onClose?() }
    @objc private func replaceOne() { onReplace?(false) }
    @objc private func replaceEvery() { onReplace?(true) }
}

@MainActor
final class FindToolButton: NSButton {
    private var hovered = false
    private var area: NSTrackingArea?
    override init(frame: NSRect) { super.init(frame: frame); isBordered = false; imagePosition = .imageOnly }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(next); area = next
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (hovered || isHighlighted || state == .on) {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 5, yRadius: 5).fill()
        }
        contentTintColor = isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
        super.draw(dirtyRect)
    }
}

@MainActor
private final class FindPanelContent: NSView {
    var replacing = false { didSet { if oldValue != replacing { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let panel = bounds
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5), xRadius: 17, yRadius: 17)
        path.lineWidth = 0.75; path.stroke()
        let lines = NSBezierPath()
        if replacing { lines.move(to: NSPoint(x: 10, y: 40)); lines.line(to: NSPoint(x: panel.maxX - 10, y: 40)) }
        lines.move(to: NSPoint(x: panel.maxX - 39, y: 15)); lines.line(to: NSPoint(x: panel.maxX - 39, y: 29))
        lines.lineWidth = 0.75; lines.stroke()
    }
}
