import SwiftUI
import AppKit

struct NoteEditor: NSViewRepresentable {
    @ObservedObject private var languageSettings = LanguageSettings.shared
    @ObservedObject var store: NoteStore
    let session: NoteEditingSession
    var appearance: NoteAppearance
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let slot = NoteEditingSlot(session: session, isLibrary: false)
        session.desktopSlot = slot
        if !session.inPreview { session.mount(in: slot) }
        return slot
    }

    func updateNSView(_ slot: NSView, context: Context) {
        let host = session.host
        let editor = host.editor
        session.desktopInk = textColor
        host.updateColors(session.inPreview ? session.libraryInk : textColor)
        editor.isEditable = store.loadError == nil
        editor.updatePaperBackground(NotePalette.paperBackground(for: store.document.color))
        editor.tableCellEditor?.isEditable = editor.isEditable
        editor.loadExternalContent(store.document.content)
        session.desktopEscape = onEscape
        if !session.inPreview { editor.onEscape = onEscape }
        host.updateLanguage(bundle: languageSettings.bundle)
        (slot as? NoteEditingSlot)?.refreshMirror()
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
    private var displayedLanguage: URL?
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
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateColors(_ ink: NSColor) {
        editor.updateColors(ink)
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
        guard languageChanged || editableChanged else { return }
        displayedLanguage = bundle.bundleURL
        if languageChanged { editor.refreshImageLanguage(); editor.refreshVideoControls() }
        displayedEditable = editor.isEditable
        editor.updateFindStatus()
        editor.scheduleCodeToolbarUpdate()
        editor.needsDisplay = true // Localized placeholders live in the editor.
        editor.setAccessibilityLabel(String(localized: "Note text", bundle: bundle))
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

/// Retained by the UUID's controller, independently of either presentation slot.
@MainActor
final class NoteEditingSession {
    let host = NativeEditorHost()
    private let history = UndoManager()
    let store: NoteStore
    weak var desktopSlot: NSView?
    weak var librarySlot: NoteEditingSlot?
    var desktopInk: NSColor = NotePalette.paperText
    var libraryInk: NSColor = NotePalette.paperText
    var desktopEscape: (() -> Void)?
    private(set) var inPreview = false

    init(store: NoteStore) {
        self.store = store
        let editor = host.editor
        editor.sessionUndoManager = history
        editor.file = store.file
        editor.onContentChange = { [weak store] in store?.edit($0) }
        editor.onRemoteImageCommit = { [weak store] in store?.flush() ?? false }
        editor.onVideoCommit = { [weak store] in store?.flush() ?? false }
        editor.onAttachmentCommit = { [weak store] in store?.flush() ?? false }
        editor.onAudioCommit = { [weak store] in store?.flush() ?? false }
        editor.configure(content: store.document.content)
    }

    func mount(in slot: NSView) {
        guard host.superview !== slot else { return }
        let selection = host.editor.selectedRanges
        if let responder = host.window?.firstResponder as? NSView,
           responder === host.editor || responder.isDescendant(of: host) {
            host.window?.makeFirstResponder(nil)
        }
        let previous = host.superview as? NoteEditingSlot
        host.removeFromSuperview()
        host.frame = slot.bounds
        host.autoresizingMask = [.width, .height]
        slot.addSubview(host)
        host.editor.selectedRanges = selection
        previous?.refreshMirror()
        (slot as? NoteEditingSlot)?.refreshMirror()
    }

    func prepareToLeave() -> Bool {
        host.editor.commitForHandoff()
        guard host.editor.prepareAudioForHiding() else { return false }
        return store.flush()
    }

    func beginPreview(in slot: NSView) -> Bool {
        guard store.document.deletedAt == nil,
              store.loadError == nil, prepareToLeave() else { return false }
        librarySlot = slot as? NoteEditingSlot
        inPreview = true
        host.updateColors(libraryInk)
        host.editor.isEditable = true
        host.updateLanguage(bundle: LanguageSettings.shared.bundle)
        host.editor.onEscape = {} // Esc must not invoke desktop shelving/focus routing.
        mount(in: slot)
        return true
    }

    func endPreview() -> Bool {
        guard inPreview else { return true }
        guard prepareToLeave() else { return false }
        inPreview = false
        host.updateColors(desktopInk)
        host.editor.onEscape = desktopEscape
        if let desktopSlot { mount(in: desktopSlot) }
        return true
    }
}


/// The inactive presentation mirrors the document. Clicking it hands back the
/// UUID's one real editor, so both locations remain directly editable without
/// independent editing histories or a user-visible mode switch.
@MainActor
final class NoteEditingSlot: NSView {
    let session: NoteEditingSession
    let isLibrary: Bool
    private var mirror: NSScrollView?
    private var mirroredContent: NoteContent?
    private var mirroredWidth: CGFloat = 0
    private var mirroredInk: NSColor?
    init(session: NoteEditingSession, isLibrary: Bool) {
        self.session = session; self.isLibrary = isLibrary
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    @discardableResult func claimEditor() -> Bool {
        if session.host.superview === self { return true }
        let success = isLibrary ? session.beginPreview(in: self) : session.endPreview()
        if success { window?.makeFirstResponder(session.host.editor.tableCellEditor ?? session.host.editor) }
        return success
    }
    func refreshMirror() {
        if session.host.superview === self {
            mirror?.removeFromSuperview(); mirror = nil; mirroredContent = nil
            return
        }
        if mirror == nil {
            let scroll = NSScrollView(frame: bounds)
            scroll.autoresizingMask = [.width, .height]
            scroll.drawsBackground = false
            let text = NSTextView(frame: bounds)
            text.drawsBackground = false; text.isEditable = false; text.isSelectable = false
            text.usesAdaptiveColorMappingForDarkAppearance = false
            text.isVerticallyResizable = true; text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.textContainerInset = session.host.editor.textContainerInset
            text.textContainer?.lineFragmentPadding = 0
            scroll.documentView = text
            addSubview(scroll); mirror = scroll
        }
        let content = session.store.document.content
        let ink = isLibrary ? session.libraryInk : session.desktopInk
        guard content != mirroredContent || abs(mirroredWidth - bounds.width) > 0.5 || mirroredInk != ink else { return }
        mirroredContent = content; mirroredWidth = bounds.width; mirroredInk = ink
        let rendered = BlockTextCodec.render(content, color: ink,
            width: max(100, bounds.width - NoteLayout.editorHorizontalInset * 2), image: { [file = session.store.file] image in
                NSImage(contentsOf: file.imageURL(image.id))
            })
        (mirror?.documentView as? NSTextView)?.textStorage?.setAttributedString(rendered)
    }
    override func layout() { super.layout(); refreshMirror() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return session.host.superview === self ? hit : self
    }
    override func mouseDown(with event: NSEvent) {
        guard claimEditor() else { return }
        layoutSubtreeIfNeeded()
        let point = convert(event.locationInWindow, from: nil)
        if let target = session.host.hitTest(point) { target.mouseDown(with: event) }
    }
}
