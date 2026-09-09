import AppKit

/// This native picker never starts an NSMenu tracking session. NSTextView keeps
/// handling text, deletion, undo and IME while the nonactivating panel is open.
@MainActor
final class SlashCommandMenu {
    struct Entry {
        let kind: NoteBlockKind
        let title: String
        var importsAudio = false
        var isMedia: Bool { kind == .code || kind == .image || kind == .audio }

        func inputHint(bundle: Bundle) -> String {
            let prefix: String
            switch kind {
            case .heading: prefix = "#"
            case .subheading: prefix = "##"
            case .heading3: prefix = "###"
            case .heading4: prefix = "####"
            case .bullet: prefix = "-"
            case .orderedList: prefix = "1."
            case .divider: prefix = "---"
            case .task: prefix = "[]"
            case .quote: prefix = "\""
            case .code: prefix = "```"
            case .paragraph, .image, .table, .audio: return ""
            }
            return prefix
        }

        var symbol: String? {
            switch kind {
            case .paragraph: nil
            case .heading, .subheading, .heading3, .heading4: "textformat.size"
            case .bullet: "list.bullet"
            case .orderedList: "list.number"
            case .divider: "minus"
            case .table: "tablecells"
            case .task: "checkmark.square"
            case .quote: "text.quote"
            case .code: "chevron.left.forwardslash.chevron.right"
            case .audio: importsAudio ? "waveform" : "mic"
            case .image: "photo"
            }
        }
    }

    let blockID: UUID
    let entries: [Entry]
    private(set) var selectedIndex = 0
    var onChoose: ((NoteBlockKind) -> Void)?
    var onImportAudio: (() -> Void)?
    var onDismiss: (() -> Void)?
    private var panel: SlashSuggestionPanel?
    private let bundle: Bundle
    private let pointerLocation: () -> NSPoint
    private var lastPointerLocation: NSPoint
    private var usesKeyboardSelection = true
    private(set) var contentView: SlashMenuContentView?

    init(blockID: UUID, entries: [Entry], bundle: Bundle = .main,
         pointerLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation }) {
        self.blockID = blockID
        self.entries = entries
        self.bundle = bundle
        self.pointerLocation = pointerLocation
        lastPointerLocation = pointerLocation()
    }

    func moveSelection(_ delta: Int) {
        guard !entries.isEmpty else { return }
        selectedIndex = (selectedIndex + delta % entries.count + entries.count) % entries.count
        usesKeyboardSelection = true
        // Scrolling rows under a stationary pointer must not take selection
        // away from the keyboard, even if tracking events arrive afterward.
        lastPointerLocation = pointerLocation()
        updateSelection(scroll: true)
    }

    func chooseSelected() {
        guard entries.indices.contains(selectedIndex) else { return }
        if entries[selectedIndex].importsAudio { onImportAudio?() } else { onChoose?(entries[selectedIndex].kind) }
    }

    /// Also used for offscreen layout checks without opening user windows.
    func makeContentView(maximumHeight: CGFloat) -> SlashMenuContentView {
        let view = SlashMenuContentView(entries: entries, bundle: bundle, maximumHeight: maximumHeight)
        view.onHover = { [weak self] index in
            guard let self, entries.indices.contains(index) else { return }
            let point = pointerLocation()
            guard point != lastPointerLocation else { return }
            lastPointerLocation = point
            selectedIndex = index
            usesKeyboardSelection = false
            updateSelection()
        }
        view.onChoose = { [weak self] index in
            guard let self else { return }
            selectedIndex = index
            chooseSelected()
        }
        view.onDismiss = { [weak self] in self?.onDismiss?() }
        contentView = view
        updateSelection()
        return view
    }

    func show(in parent: NSWindow, at caret: NSRect, appearance: NSAppearance) {
        guard panel == nil, !entries.isEmpty else { return }
        let available = (parent.screen?.visibleFrame ?? parent.frame).insetBy(dx: 8, dy: 8)
        let below = caret.minY - available.minY - 6
        let above = available.maxY - caret.maxY - 6
        let view = makeContentView(maximumHeight: max(100, min(440, max(below, above))))
        let size = view.frame.size
        let y = below >= size.height ? caret.minY - size.height - 6 : caret.maxY + 6
        let frame = NSRect(x: min(max(caret.minX - 10, available.minX), available.maxX - size.width),
                           y: min(max(y, available.minY), available.maxY - size.height),
                           width: size.width, height: size.height)
        let popup = SlashSuggestionPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: true)
        popup.isReleasedWhenClosed = false
        popup.isOpaque = false
        popup.backgroundColor = .clear
        popup.hasShadow = true
        popup.level = parent.level
        popup.animationBehavior = .none
        popup.acceptsMouseMovedEvents = true
        popup.collectionBehavior = [.transient, .fullScreenAuxiliary]
        popup.appearance = appearance
        popup.contentView = view
        panel = popup
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(parentChanged(_:)), name: name, object: parent)
        }
        parent.addChildWindow(popup, ordered: .above)
        popup.orderFront(nil)
    }

    func dismiss() {
        NotificationCenter.default.removeObserver(self)
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        contentView = nil
    }

    func updateAppearance(_ appearance: NSAppearance) {
        panel?.appearance = appearance
        contentView?.appearance = appearance
        contentView?.needsDisplay = true
        updateSelection()
    }

    @objc private func parentChanged(_ notification: Notification) { onDismiss?() }

    private func updateSelection(scroll: Bool = false) {
        contentView?.select(index: selectedIndex, keyboard: usesKeyboardSelection, scroll: scroll)
    }
}

final class SlashSuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A scrolling list with a dismiss action that stays visible on small displays.
final class SlashMenuContentView: NSView {
    var onHover: ((Int) -> Void)?
    var onChoose: ((Int) -> Void)?
    var onDismiss: (() -> Void)?
    let scrollView = NSScrollView()
    private(set) var rows: [SlashSuggestionButton] = []
    let closeButton = SlashSuggestionButton(frame: .zero)
    private let list = SlashMenuListView()
    private static let rowHeight: CGFloat = 36
    private static let footerHeight: CGFloat = 42
    override var isFlipped: Bool { true }

    init(entries: [SlashCommandMenu.Entry], bundle: Bundle, maximumHeight: CGFloat) {
        super.init(frame: .zero)
        let width: CGFloat = 304
        var y: CGFloat = 4
        for isMedia in [false, true] {
            let group = entries.enumerated().filter { $0.element.isMedia == isMedia }
            guard !group.isEmpty else { continue }
            if y > 4 {
                let divider = NSBox(frame: NSRect(x: 14, y: y + 7, width: width - 28, height: 1))
                divider.boxType = .separator
                list.addSubview(divider)
                y += 16
            }
            let title = isMedia ? String(localized: "Media", bundle: bundle) : String(localized: "Basic blocks", bundle: bundle)
            let header = NSTextField(labelWithString: title)
            header.font = .systemFont(ofSize: 11, weight: .semibold)
            header.textColor = .secondaryLabelColor
            header.frame = NSRect(x: 14, y: y + 8, width: width - 28, height: 18)
            list.addSubview(header)
            y += 32
            for (index, entry) in group {
                let button = SlashSuggestionButton(frame: NSRect(x: 6, y: y, width: width - 14, height: Self.rowHeight))
                button.title = entry.title
                button.shortcutHint = entry.inputHint(bundle: bundle)
                button.setAccessibilityHelp(button.shortcutHint)
                button.headingLevel = entry.kind.headingLevel
                button.letterIcon = entry.kind == .paragraph ? "T" : nil
                button.symbolName = entry.symbol
                button.tag = index
                button.target = self
                button.action = #selector(chooseRow(_:))
                button.onHover = { [weak self] in self?.onHover?(index) }
                list.addSubview(button)
                rows.append(button)
                y += Self.rowHeight
            }
        }
        list.frame = NSRect(x: 0, y: 0, width: width - 2, height: y + 6)
        let height = min(list.frame.height + Self.footerHeight + 2, max(100, maximumHeight))
        frame = NSRect(x: 0, y: 0, width: width, height: height)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        scrollView.frame = NSRect(x: 1, y: 1, width: width - 2, height: height - Self.footerHeight - 1)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = list
        addSubview(scrollView)
        closeButton.frame = NSRect(x: 6, y: height - Self.footerHeight + 3, width: width - 12, height: Self.footerHeight - 8)
        closeButton.title = String(localized: "Close menu", bundle: bundle)
        closeButton.shortcutHint = "esc"
        closeButton.isFooter = true
        closeButton.target = self
        closeButton.action = #selector(closeMenu(_:))
        addSubview(closeButton)
        setAccessibilityLabel(String(localized: "Content blocks", bundle: bundle))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func select(index: Int, keyboard: Bool, scroll: Bool) {
        for row in rows {
            row.showsSelection = row.tag == index
            row.showsKeyboardFocus = keyboard && row.tag == index
        }
        if scroll, let row = rows.first(where: { $0.tag == index }) {
            row.scrollToVisible(row.bounds.insetBy(dx: 0, dy: -4))
        }
    }

    @objc private func chooseRow(_ sender: NSButton) { onChoose?(sender.tag) }
    @objc private func closeMenu(_ sender: NSButton) { onDismiss?() }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        EditorMenuPalette.background.setFill()
        outline.fill()
        EditorMenuPalette.border.setStroke()
        outline.lineWidth = 0.75
        outline.stroke()
        NSColor.separatorColor.setFill()
        NSRect(x: 1, y: bounds.height - Self.footerHeight, width: bounds.width - 2, height: 0.5).fill()
    }
}

private final class SlashMenuListView: NSView {
    override var isFlipped: Bool { true }
}

final class SlashSuggestionButton: NSButton {
    var onHover: (() -> Void)?
    var shortcutHint = ""
    var headingLevel: Int?
    var letterIcon: String?
    var isFooter = false
    var symbolName: String? {
        didSet {
            image = symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
                .withSymbolConfiguration(.init(pointSize: 17, weight: symbolName == "minus" ? .ultraLight : .regular))
        }
    }
    private var hoverArea: NSTrackingArea?
    private var isHovered = false
    var showsSelection = false { didSet { if oldValue != showsSelection { needsDisplay = true } } }
    var showsKeyboardFocus = false { didSet { if oldValue != showsKeyboardFocus { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        refusesFirstResponder = true
        focusRingType = .none
        setButtonType(.momentaryChange)
        font = .systemFont(ofSize: 14)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverArea == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    // Entry/exit events can be caused by scrolling or by the popup appearing.
    // Only pointer movement is an intent to change the selected menu item.
    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseMoved(with event: NSEvent) { onHover?() }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if showsSelection || isFooter && isHovered || isHighlighted {
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
            EditorMenuPalette.selection.setFill()
            shape.fill()
        }
        if showsKeyboardFocus {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 7, yRadius: 7)
            NSColor.controlAccentColor.setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }
        let color = NSColor.labelColor
        let font = font ?? .systemFont(ofSize: 14)
        let centerY = bounds.midY
        if !isFooter {
            if let letterIcon {
                let letter = NSAttributedString(string: letterIcon, attributes: [.font: NSFont.systemFont(ofSize: 19, weight: .medium), .foregroundColor: color])
                letter.draw(at: NSPoint(x: 21 - letter.size().width / 2, y: centerY - letter.size().height / 2))
            } else if let headingLevel {
                let heading = NSMutableAttributedString(string: "H", attributes: [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: color])
                heading.append(NSAttributedString(string: String(headingLevel), attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color, .baselineOffset: -1.5]))
                heading.draw(at: NSPoint(x: 11, y: centerY - heading.size().height / 2))
            } else if let image {
                let tinted = image.withSymbolConfiguration(.init(paletteColors: [color])) ?? image
                tinted.draw(in: NSRect(x: 11, y: centerY - 10, width: 20, height: 20))
            }
        }
        let hint = NSAttributedString(string: shortcutHint, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        let hintWidth = hint.size().width
        hint.draw(at: NSPoint(x: bounds.width - 12 - hintWidth, y: centerY - hint.size().height / 2))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let label = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        let x: CGFloat = isFooter ? 12 : 42
        label.draw(in: NSRect(x: x, y: centerY - label.size().height / 2,
                              width: max(0, bounds.width - x - hintWidth - 24), height: label.size().height))
    }
}
