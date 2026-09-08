import SwiftUI
import AppKit

struct NoteEditor: NSViewRepresentable {
    @ObservedObject private var languageSettings = LanguageSettings.shared
    @ObservedObject var store: NoteStore
    var appearance: NoteAppearance
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NativeEditorHost {
        let host = NativeEditorHost()
        let editor = host.editor
        editor.file = store.file
        editor.noteColor = textColor
        editor.updatePaperBackground(NotePalette.paperBackground(for: store.document.color))
        host.updateColors(textColor)
        editor.onContentChange = { [weak store] in store?.edit($0) }
        editor.onEscape = onEscape
        editor.configure(content: store.document.content)
        return host
    }

    func updateNSView(_ host: NativeEditorHost, context: Context) {
        let editor = host.editor
        host.updateColors(textColor)
        editor.isEditable = store.loadError == nil
        editor.updatePaperBackground(NotePalette.paperBackground(for: store.document.color))
        editor.tableCellEditor?.isEditable = editor.isEditable
        editor.loadExternalContent(store.document.content)
        editor.onEscape = onEscape
        host.updateLanguage(bundle: languageSettings.bundle)
        if context.coordinator.lastFocusRequest != store.focusRequest {
            context.coordinator.lastFocusRequest = store.focusRequest
            DispatchQueue.main.async { [weak editor, weak store] in
                guard let editor, let store, !store.isCollapsed, !store.document.isShelved,
                      let window = editor.window else { return }
                let responder: NSTextView = editor.tableCellEditor as NSTextView? ?? editor
                if window.makeFirstResponder(responder) {
                    editor.scheduleInsertionPointRefresh()
                }
            }
        }
    }

    private var textColor: NSColor {
        appearance.textColor
    }

    final class Coordinator { var lastFocusRequest = 0 }
}

final class NativeEditorHost: NSView {
    let editor = PaperTextView(usingTextLayoutManager: true)
    private let scroll = NSScrollView()
    private let blockButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private var status: NoteEditorStatus?
    private var displayedLanguage: URL?
    private var displayedKind: NoteBlockKind?
    private var displayedStatus: NoteEditorStatus?
    private var displayedEditable: Bool?

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        editor.isRichText = true
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.usesFontPanel = false
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: NoteLayout.editorHorizontalInset, height: 8)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineFragmentPadding = 0
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = editor
        blockButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        blockButton.imagePosition = .imageLeading
        blockButton.bezelStyle = .inline
        blockButton.isBordered = false
        blockButton.font = .systemFont(ofSize: 11)
        blockButton.target = editor
        blockButton.action = #selector(PaperTextView.showBlockMenu(_:))
        blockButton.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        let bar = NSStackView(views: [blockButton, statusLabel])
        bar.orientation = .horizontal
        bar.spacing = 10
        for view in [scroll, bar] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor), bar.heightAnchor.constraint(equalToConstant: 24)
        ])
        editor.onStatusChange = { [weak self] value in
            self?.status = value
            self?.updateLanguage(bundle: LanguageSettings.shared.bundle)
        }
        editor.onBlockKindChange = { [weak self] _ in
            self?.updateLanguage(bundle: LanguageSettings.shared.bundle)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateColors(_ ink: NSColor) {
        editor.updateColors(ink)
        let secondary = NotePalette.secondaryText(for: ink)
        if blockButton.contentTintColor != secondary { blockButton.contentTintColor = secondary }
        if statusLabel.textColor != secondary { statusLabel.textColor = secondary }
        // A light paper surface still needs a dark scrollbar in Dark Aqua.
        let knob: NSScroller.KnobStyle = ink == NotePalette.paperText ? .dark : .default
        if scroll.scrollerKnobStyle != knob { scroll.scrollerKnobStyle = knob }
    }

    override func layout() {
        super.layout()
        // Keep the blank area below short notes inside the editable view so a
        // click can create a paragraph after a terminal code block.
        let height = scroll.contentView.bounds.height
        editor.minSize = NSSize(width: 0, height: height)
        if editor.frame.height < height {
            editor.setFrameSize(NSSize(width: editor.frame.width, height: height))
        }
    }

    func updateLanguage(bundle: Bundle) {
        let languageChanged = displayedLanguage != bundle.bundleURL
        let editableChanged = displayedEditable != editor.isEditable
        let kind = editor.currentBlockKind
        guard languageChanged || displayedKind != kind || displayedStatus != status || editableChanged else { return }
        displayedLanguage = bundle.bundleURL
        displayedKind = kind
        displayedStatus = status
        displayedEditable = editor.isEditable
        if languageChanged || editableChanged {
            editor.scheduleCodeToolbarUpdate()
            editor.needsDisplay = true // Localized placeholders live in the editor.
        }
        editor.setAccessibilityLabel(String(localized: "Note text", bundle: bundle))
        blockButton.title = editor.currentBlockTitle
        blockButton.toolTip = String(localized: "Insert or change a block. Type / in an empty paragraph.", bundle: bundle)
        blockButton.isEnabled = editor.isEditable
        statusLabel.stringValue = status?.description(bundle: bundle) ?? (editor.currentBlockKind == .table
            ? String(localized: "Tab next cell · ⌘↩ return to text", bundle: bundle)
            : editor.currentBlockKind == .code
            ? String(localized: "⌘↩ return to text", bundle: bundle)
            : String(localized: "/ blocks · ⌘B bold", bundle: bundle))
        statusLabel.toolTip = statusLabel.stringValue
    }
}

struct WindowDragRegion: NSViewRepresentable {
    var onDoubleClick: () -> Void
    var onContextMenu: (() -> NSMenu?)? = nil
    var hasCenteredIcon = false
    func makeNSView(context: Context) -> NSView {
        let view = NoteWindowDragView()
        view.onDoubleClick = onDoubleClick
        view.onContextMenu = onContextMenu
        view.hasCenteredIcon = hasCenteredIcon
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? NoteWindowDragView)?.onDoubleClick = onDoubleClick
        (nsView as? NoteWindowDragView)?.onContextMenu = onContextMenu
        (nsView as? NoteWindowDragView)?.hasCenteredIcon = hasCenteredIcon
    }
}

final class NoteWindowDragView: NSView {
    var onDoubleClick: (() -> Void)?
    var onContextMenu: (() -> NSMenu?)?
    var hasCenteredIcon = false

    private var centeredIconFrame: NSRect? {
        guard hasCenteredIcon, let contentView = window?.contentView else { return nil }
        let centerX = convert(NSPoint(x: contentView.bounds.midX, y: 0), from: contentView).x
        return NSRect(x: centerX - 13, y: bounds.midY - 14, width: 26, height: 28)
    }

    func containsDragPoint(_ windowPoint: NSPoint) -> Bool {
        let point = convert(windowPoint, from: nil)
        // The centered SwiftUI button overlays this region. Let both the panel
        // event router and AppKit hit testing pass its clicks through.
        return bounds.intersection(visibleRect).contains(point)
            && centeredIconFrame?.contains(point) != true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if centeredIconFrame?.contains(convert(point, from: superview)) == true { return nil }
        return super.hitTest(point)
    }
    override func menu(for event: NSEvent) -> NSMenu? { onContextMenu?() }
    func showColorMenu(with event: NSEvent) {
        guard let menu = onContextMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        // Let WindowServer track the original event instead of repeatedly
        // repositioning the window from asynchronously sampled pointer coordinates.
        window?.performDrag(with: event)
    }
    override var mouseDownCanMoveWindow: Bool { false }
}
