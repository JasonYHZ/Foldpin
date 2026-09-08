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
        editor.onContentChange = { [weak store] in store?.edit($0) }
        editor.onEscape = onEscape
        editor.configure(content: store.document.content)
        return host
    }

    func updateNSView(_ host: NativeEditorHost, context: Context) {
        let editor = host.editor
        editor.updateColors(textColor)
        editor.isEditable = store.loadError == nil
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
        appearance == .paper ? NotePalette.paperText : .labelColor
    }

    final class Coordinator { var lastFocusRequest = 0 }
}

final class NativeEditorHost: NSView {
    let editor = PaperTextView(usingTextLayoutManager: true)
    private let scroll = NSScrollView()
    private let blockButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private var status: NoteEditorStatus?

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
        editor.textContainerInset = NSSize(width: 32, height: 16)
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
        editor.scheduleCodeToolbarUpdate()
        editor.needsDisplay = true
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
    func makeNSView(context: Context) -> NSView {
        let view = NoteWindowDragView()
        view.onDoubleClick = onDoubleClick
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? NoteWindowDragView)?.onDoubleClick = onDoubleClick
    }
}

final class NoteWindowDragView: NSView {
    var onDoubleClick: (() -> Void)?
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
