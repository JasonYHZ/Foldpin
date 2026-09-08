import AppKit

/// A suggestion list, not an NSMenu tracking session: the text view keeps
/// receiving typing, deletion, undo and input-method events while it is open.
@MainActor
final class SlashCommandMenu {
    struct Entry {
        let kind: NoteBlockKind
        let title: String
    }

    let blockID: UUID
    let entries: [Entry]
    private(set) var selectedIndex = 0
    var onChoose: ((NoteBlockKind) -> Void)?
    var onDismiss: (() -> Void)?
    private var panel: SlashSuggestionPanel?
    private var buttons: [SlashSuggestionButton] = []
    private let rowHeight: CGFloat = 28

    init(blockID: UUID, entries: [Entry]) {
        self.blockID = blockID
        self.entries = entries
    }

    func moveSelection(_ delta: Int) {
        guard !entries.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + entries.count) % entries.count
        updateSelection()
    }

    func chooseSelected() {
        guard entries.indices.contains(selectedIndex) else { return }
        onChoose?(entries[selectedIndex].kind)
    }

    func show(in parent: NSWindow, at caret: NSRect, appearance: NSAppearance) {
        guard panel == nil, !entries.isEmpty else { return }
        let width: CGFloat = 236
        let height = CGFloat(entries.count) * rowHeight + 12
        let available = parent.screen?.visibleFrame ?? parent.frame
        let below = caret.minY - height - 5
        let y = below >= available.minY ? below : caret.maxY + 5
        let frame = NSRect(x: min(max(caret.minX, available.minX), available.maxX - width),
                           y: min(max(y, available.minY), available.maxY - height), width: width, height: height)
        let popup = SlashSuggestionPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: true)
        popup.isReleasedWhenClosed = false
        popup.isOpaque = false
        popup.backgroundColor = .clear
        popup.hasShadow = true
        popup.level = parent.level
        popup.animationBehavior = .none
        popup.collectionBehavior = [.transient, .fullScreenAuxiliary]
        popup.appearance = appearance
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        for (index, entry) in entries.enumerated() {
            let button = SlashSuggestionButton(frame: NSRect(x: 6, y: height - 6 - CGFloat(index + 1) * rowHeight,
                                                            width: width - 12, height: rowHeight))
            button.title = entry.title
            button.font = .systemFont(ofSize: 12)
            button.alignment = .left
            button.isBordered = false
            button.imagePosition = .imageLeading
            button.image = NSImage(systemSymbolName: symbol(entry.kind), accessibilityDescription: nil)
            button.tag = index
            button.target = self
            button.action = #selector(chooseRow(_:))
            button.onHover = { [weak self] in
                self?.selectedIndex = index
                self?.updateSelection()
            }
            background.addSubview(button)
            buttons.append(button)
        }
        popup.contentView = background
        panel = popup
        updateSelection()
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
        buttons.removeAll()
    }

    func updateAppearance(_ appearance: NSAppearance) {
        panel?.appearance = appearance
        updateSelection()
    }

    @objc private func parentChanged(_ notification: Notification) { onDismiss?() }

    @objc private func chooseRow(_ sender: NSButton) {
        selectedIndex = sender.tag
        chooseSelected()
    }

    private func updateSelection() {
        for button in buttons { button.showsSelection = button.tag == selectedIndex }
    }

    private func symbol(_ kind: NoteBlockKind) -> String {
        switch kind {
        case .paragraph: "text.alignleft"
        case .heading: "textformat.size.larger"
        case .subheading: "textformat.size.smaller"
        case .bullet: "list.bullet"
        case .task: "checklist"
        case .quote: "text.quote"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .image: "photo"
        }
    }
}

final class SlashSuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class SlashSuggestionButton: NSButton {
    var onHover: (() -> Void)?
    private var hoverArea: NSTrackingArea?
    var showsSelection = false {
        didSet {
            let color: NSColor = showsSelection ? .selectedMenuItemTextColor : .labelColor
            attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: color, .font: font ?? NSFont.systemFont(ofSize: 12)])
            contentTintColor = color
            needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func draw(_ dirtyRect: NSRect) {
        if showsSelection {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
}
