import AppKit

/// One reusable native overlay per editor, bound to the hovered block's ID.
/// Explicit menu clicks may use NSMenu; typing never opens a blocking menu.
@MainActor
final class CodeBlockToolbar: NSView {
    private final class Button: NSButton {
        override var needsPanelToBecomeKey: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    var onSelectLanguage: ((UUID, CodeLanguage) -> Void)?
    var onCopy: ((UUID) -> Bool)?
    var onMenuFinished: (() -> Void)?
    var onPointerChange: ((NSPoint) -> Void)?
    private(set) var blockID: UUID?
    private(set) var isPresentingMenu = false
    private let languageButton = Button()
    private let copyButton = Button()
    private var language: CodeLanguage = .plain
    private var displayedText: String?
    private var pointerTrackingArea: NSTrackingArea?
    private var bundle: Bundle = .main
    private var theme: NativeCodeTheme = .github
    private var copyGeneration = UUID()
    private var copied = false

    override var isFlipped: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 160, height: 28))
        for button in [languageButton, copyButton] {
            button.isBordered = false
            button.refusesFirstResponder = true
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.imageScaling = .scaleProportionallyDown
            addSubview(button)
        }
        languageButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        languageButton.imagePosition = .imageTrailing
        languageButton.action = #selector(showLanguages(_:))
        copyButton.imagePosition = .imageOnly
        copyButton.action = #selector(copyBlock(_:))
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard pointerTrackingArea == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerChange?(event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerChange?(event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerChange?(event.locationInWindow)
    }

    func update(block: NoteBlock, bundle: Bundle, theme: NativeCodeTheme, canChangeLanguage: Bool) {
        let blockChanged = blockID != block.id
        let title = block.language.displayTitle(for: block.text, bundle: bundle)
        let labelsChanged = blockChanged || self.bundle !== bundle || language != block.language || displayedText != block.text || languageButton.title != title
        let themeChanged = self.theme !== theme || blockID == nil
        if blockChanged { copied = false; copyGeneration = UUID() }
        blockID = block.id
        language = block.language
        displayedText = block.text
        self.bundle = bundle
        self.theme = theme
        if labelsChanged {
            languageButton.title = title
            if block.language == .automatic, !block.text.isEmpty,
               CodeSyntaxEngine.shared.cachedLanguage(block.text) == .plain {
                languageButton.toolTip = String(localized: "Not enough context to identify the language. Choose a language manually.", bundle: bundle)
            } else if block.language != .plain, block.text.utf16.count >= CodeSyntaxEngine.maximumSourceLength {
                languageButton.toolTip = String(localized: "Highlighting is paused for long code blocks. You can still edit and copy all content.", bundle: bundle)
            } else {
                languageButton.toolTip = String(localized: "Code Language", bundle: bundle)
            }
            languageButton.setAccessibilityLabel(String(localized: "Code Language", bundle: bundle))
            languageButton.setAccessibilityValue(languageButton.title)
            updateCopyLabel()
            let languageWidth = max(64, languageButton.fittingSize.width + 8)
            let size = NSSize(width: languageWidth + 48, height: 28)
            if frame.size != size { frame.size = size }
            languageButton.frame = NSRect(x: 6, y: 2, width: languageWidth, height: 24)
            copyButton.frame = NSRect(x: languageWidth + 17, y: 2, width: 26, height: 24)
        }
        if languageButton.isEnabled != canChangeLanguage { languageButton.isEnabled = canChangeLanguage }
        if themeChanged {
            languageButton.contentTintColor = theme.foreground
            copyButton.contentTintColor = theme.foreground
        }
        if labelsChanged || themeChanged { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        theme.background.setFill()
        shape.fill()
        theme.border.setStroke()
        shape.lineWidth = 0.75
        shape.stroke()
        theme.border.setFill()
        NSRect(x: copyButton.frame.minX - 5, y: 7, width: 1, height: 14).fill()
    }

    @objc private func showLanguages(_ sender: NSButton) {
        guard blockID != nil, languageButton.isEnabled else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for choice in CodeLanguage.allCases {
            let item = NSMenuItem(title: choice.title(bundle: bundle), action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.state = choice == language ? .on : .off
            menu.addItem(item)
        }
        isPresentingMenu = true
        defer { isPresentingMenu = false; onMenuFinished?() }
        menu.popUp(positioning: nil, at: NSPoint(x: languageButton.frame.minX, y: bounds.maxY + 4), in: self)
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let id = blockID, let raw = sender.representedObject as? String, let choice = CodeLanguage(rawValue: raw) else { return }
        onSelectLanguage?(id, choice)
    }

    @objc private func copyBlock(_ sender: NSButton) {
        guard let id = blockID, onCopy?(id) == true else { return }
        copied = true
        let generation = UUID()
        copyGeneration = generation
        updateCopyLabel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, copyGeneration == generation else { return }
            copied = false
            updateCopyLabel()
        }
    }

    private func updateCopyLabel() {
        let label = copied ? String(localized: "Copied", bundle: bundle) : String(localized: "Copy Code", bundle: bundle)
        copyButton.image = NSImage(systemSymbolName: copied ? "checkmark" : "doc.on.doc", accessibilityDescription: nil)
        copyButton.toolTip = label
        copyButton.setAccessibilityLabel(label)
    }
}
