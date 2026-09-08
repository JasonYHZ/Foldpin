import AppKit
import SwiftUI
import OSLog
import Combine

/// One retained editor and undo history per note, including while shelved.
@MainActor
final class PaperWindowController: NSObject, NSWindowDelegate {
    let id: UUID
    let store: NoteStore
    let titlebarState = NoteTitlebarState()
    private(set) var paper: PaperPanel!
    private var paperShadow: NoteShadowWindow?
    private var restoringFrame = false
    private var paperIsCollapsed = false
    private var expandedMaximumSize = NSSize.zero
    private var pendingGeometryUpdate: Task<Void, Never>?
    private var colorObservation: AnyCancellable?
    private var languageSettings: LanguageSettings { .shared }
    #if DEBUG
    private static let geometryLog = Logger(subsystem: "Foldpin", category: "WindowGeometry")
    #endif
    var onActivate: ((UUID) -> Void)?
    var onStateChange: (() -> Void)?
    var onShelved: ((UUID, Bool) -> Void)?

    init(entry: NoteLibrary.Entry, initialFrame: NSRect? = nil) {
        id = entry.id
        store = entry.store
        super.init()
        store.localizationBundle = languageSettings.bundle
        createPaper(initialFrame: initialFrame)
    }

    var isVisible: Bool { paper.isVisible }
    var isKey: Bool { paper.isKeyWindow }

    private var workingScreen: NSScreen {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func createPaper(initialFrame: NSRect?) {
        let screen = workingScreen.visibleFrame
        let initial = store.document.frame ?? initialFrame.map(NoteFrame.init) ?? NoteFrame(CGRect(x: screen.maxX - 452, y: screen.midY - 170, width: 360, height: 340))
        let frame = initial.fitted(to: NSScreen.screens.map(\.visibleFrame), fallback: screen)
        // Hiding a titled window's title bar keeps its system frame. Use an
        // undecorated panel so only the note's own rounded surface is visible.
        // A paper is an editable document. Nonactivating panels can borrow key
        // focus while the other application remains active, which conflicts
        // with click activation and can cancel the first resize gesture.
        // Passive restoration is controlled by showPaper(focus: false), not
        // by preventing activation at the WindowServer level.
        paper = PaperPanel(contentRect: frame, styleMask: [.borderless, .closable, .resizable], backing: .buffered, defer: false)
        paper.title = String(localized: "Foldpin Note", bundle: languageSettings.bundle)
        // This panel is the document window, not an auxiliary dialog. Window
        // managers discover it through the standard accessibility window role.
        paper.setAccessibilitySubrole(.standardWindow)
        paper.onActivate = { [weak self] in self?.activatePaper() }
        paper.onToggleCollapsed = { [weak self] in self?.toggleCollapsed() }
        paper.onRequestClose = { [weak self] in _ = self?.shelvePaper() }
        paper.onEndResize = { [weak self] in self?.recordGeometry() }
        paper.onBeginMove = { [weak self] in self?.prepareForMove() }
        paper.isReleasedWhenClosed = false
        paper.isMovable = true
        // Only the explicit header drag region initiates a native window drag.
        paper.isMovableByWindowBackground = false
        paper.hidesOnDeactivate = false
        paper.becomesKeyOnlyIfNeeded = false
        paper.isFloatingPanel = true
        paper.isOpaque = false
        paper.backgroundColor = .clear
        // The system shadow also outlines this borderless panel's rectangular
        // frame when it becomes key, outside the glass's rounded corners.
        paper.hasShadow = false
        expandedMaximumSize = paper.contentMaxSize
        paper.contentMinSize = NSSize(width: NoteLayout.minimumWidth, height: NoteLayout.minimumExpandedHeight)
        paper.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
        paper.delegate = self
        let hosting = TransparentNoteHostingView(rootView: ContentView(store: store, titlebarState: titlebarState,
            onPin: { [weak self] in self?.togglePin() },
            onCollapse: { [weak self] in self?.toggleCollapsed() },
            onShelve: { [weak self] in _ = self?.shelvePaper() },
            onRetryLoad: { [weak self] in self?.retryLoad() },
            onRevealError: { [weak self] in self?.revealError() },
            onColorMenu: { [weak self] in self?.makeColorMenu() }))
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        let surface = NoteWindowSurface(content: hosting, onHoverChange: { [weak state = titlebarState] in
            state?.setPointerInside($0)
        })
        paper.contentView = surface
        // Only color changes reach the surface, not typing or window geometry.
        colorObservation = store.$document.map(\.color).removeDuplicates().sink { [weak surface] color in
            surface?.updateColor(color)
        }
        setFrame(frame)
        // A first-launch note has no stored frame yet.
        if store.document.frame == nil { store.setFrame(frame) }
        paper.level = store.document.isPinned ? .floating : .normal
        paperShadow = NoteShadowWindow()
        applyPaperPresentation()
    }

    func applyLanguage() {
        store.localizationBundle = languageSettings.bundle
        paper.title = String(localized: "Foldpin Note", bundle: languageSettings.bundle)
    }

    func makeColorMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Note Color", bundle: languageSettings.bundle))
        menu.autoenablesItems = false
        for color in NoteColor.allCases {
            let item = NSMenuItem(title: color.title(bundle: languageSettings.bundle),
                                  action: #selector(changeColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = color.rawValue
            item.state = color == store.document.color ? .on : .off
            item.image = NotePalette.colorSwatch(for: color)
            item.isEnabled = store.loadError == nil
            menu.addItem(item)
        }
        return menu
    }

    @objc private func changeColor(_ sender: NSMenuItem) {
        guard store.loadError == nil, let raw = sender.representedObject as? String,
              let color = NoteColor(rawValue: raw) else { return }
        store.setColor(color)
        // No editor replacement, focus request, geometry change or code parse.
        onStateChange?()
    }

    func showPaper(focus: Bool) {
        if pendingGeometryUpdate != nil { recordGeometry() }
        store.setShelved(false)
        paper.level = store.document.isPinned ? .floating : .normal
        applyPaperPresentation()
        if focus {
            activatePaper()
            paper.makeKeyAndOrderFront(nil)
            if !paperIsCollapsed { store.focusRequest += 1 }
            else { paper.makeFirstResponder(nil) }
        } else { paper.orderFrontRegardless() }
        paperShadow?.show(below: paper)
        (paper.contentView as? NoteWindowSurface)?.refreshPointerPresence()
        onStateChange?()
    }

    func openExpanded() {
        if store.isCollapsed { toggleCollapsed() }
        showPaper(focus: true)
    }

    private func activatePaper() {
        onActivate?(id)
        if !NSApp.isActive { NSApp.activate() }
        paper.makeKeyAndOrderFront(nil)
        paper.makeMain()
    }

    func windowDidBecomeKey(_ notification: Notification) { onActivate?(id) }

    private func commitMarkedText() {
        if let editor = paper.firstResponder as? NSTextView, editor.hasMarkedText() {
            editor.unmarkText()
            (editor as? PaperTextView)?.commitContent()
        }
    }

    @objc func toggleCollapsed() {
        guard store.loadError == nil else { return }
        commitMarkedText()
        recordGeometry()
        let collapsing = !store.isCollapsed
        store.setCollapsed(collapsing)
        // Never hide unsaved content or its error behind a title-bar strip.
        if collapsing && !store.flush() {
            store.setCollapsed(false)
            return
        }
        paper.makeFirstResponder(nil)
        applyPaperPresentation()
        if paper.isVisible {
            paper.makeKeyAndOrderFront(nil)
            paperShadow?.show(below: paper)
            if !collapsing { store.focusRequest += 1 }
        }
        onStateChange?()
    }

    private func revealError() {
        guard paperIsCollapsed else { return }
        recordGeometry()
        store.setCollapsed(false)
        applyPaperPresentation()
        if paper.isVisible { paperShadow?.show(below: paper) }
        onStateChange?()
    }

    @discardableResult func shelvePaper(restoringFocus: Bool = true) -> Bool {
        guard store.loadError == nil else { return false }
        commitMarkedText()
        recordGeometry()
        store.setShelved(true)
        guard store.flush() else {
            store.setShelved(false)
            revealError()
            return false
        }
        let hadFocus = paper.isKeyWindow
        paperShadow?.orderOut(nil)
        paper.orderOut(nil)
        (paper.contentView as? NoteWindowSurface)?.refreshPointerPresence()
        onStateChange?()
        onShelved?(id, hadFocus && restoringFocus)
        return true
    }

    @objc func togglePin() {
        store.setPinned(!store.document.isPinned)
        paper.level = store.document.isPinned ? .floating : .normal
        if paper.isVisible { paperShadow?.show(below: paper) }
        onStateChange?()
    }

    private func retryLoad() {
        store.reload()
        if store.loadError == nil {
            applyPaperPresentation()
            if store.document.isShelved {
                paperShadow?.orderOut(nil)
                paper.orderOut(nil)
            } else { showPaper(focus: true) }
        }
        onStateChange?()
    }

    private func setFrame(_ frame: CGRect) {
        pendingGeometryUpdate?.cancel()
        pendingGeometryUpdate = nil
        restoringFrame = true
        paper.setFrame(frame, display: true)
        paperShadow?.updateFrame(for: paper)
        restoringFrame = false
    }

    private var minimumPaperSize: NSSize {
        NSSize(width: NoteLayout.minimumWidth,
               height: paperIsCollapsed ? NoteLayout.headerHeight : NoteLayout.minimumExpandedHeight)
    }

    private func applySizeLimits() {
        let minimum = minimumPaperSize
        let maximum = paperIsCollapsed
            ? NSSize(width: expandedMaximumSize.width, height: NoteLayout.headerHeight)
            : expandedMaximumSize
        guard paper.contentMinSize != minimum || paper.contentMaxSize != maximum else { return }
        // Relax a previous collapsed limit before installing either state's
        // limits. This does not fit the window to a screen or lock its size.
        paper.contentMaxSize = expandedMaximumSize
        paper.contentMinSize = minimum
        paper.contentMaxSize = maximum
    }

    private func prepareForMove() {
        traceGeometry("native-drag-start")
        applySizeLimits()
        recordGeometry()
    }

    private func applyPaperPresentation() {
        let expanded = store.document.frame?.rect ?? paper.frame
        paperIsCollapsed = store.isCollapsed
        let visible = NoteLayout.visibleFrame(expanded: expanded, collapsed: paperIsCollapsed)
        let fitted = NoteFrame(visible).fitted(to: NSScreen.screens.map(\.visibleFrame),
                                             fallback: workingScreen.visibleFrame,
                                             minimumSize: minimumPaperSize)
        restoringFrame = true
        applySizeLimits()
        setFrame(fitted)
        recordGeometry()
    }

    func screensChanged() {
        let frame = NoteFrame(paper.frame).fitted(to: NSScreen.screens.map(\.visibleFrame), fallback: workingScreen.visibleFrame,
                                                minimumSize: minimumPaperSize)
        traceGeometry("screen-parameters", proposed: frame)
        setFrame(frame); recordGeometry()
        onStateChange?()
    }

    func windowDidMove(_ notification: Notification) { scheduleGeometryRecording() }
    func windowDidResize(_ notification: Notification) {
        if !paper.isResizingByMouse { traceGeometry("window-resized") }
        paperShadow?.updateFrame(for: paper)
        scheduleGeometryRecording()
    }
    func windowDidEndLiveResize(_ notification: Notification) { recordGeometry() }

    func windowDidChangeScreen(_ notification: Notification) { traceGeometry("screen-changed") }

    private func traceGeometry(_ event: String, proposed: CGRect? = nil) {
        #if DEBUG
        guard let paper else { return }
        // Local debug diagnostics only: no note text, title, UUID or file path.
        let details = "\(event) window=\(paper.windowNumber) frame=\(NSStringFromRect(paper.frame)) "
            + "min=\(NSStringFromSize(paper.contentMinSize)) max=\(NSStringFromSize(paper.contentMaxSize)) "
            + "collapsed=\(paperIsCollapsed) restoring=\(restoringFrame) "
            + "screen=\(paper.screen.map { NSStringFromRect($0.visibleFrame) } ?? "none") "
            + "scale=\(paper.backingScaleFactor) proposed=\(proposed.map(NSStringFromRect) ?? "none")"
        Self.geometryLog.notice("\(details, privacy: .public)")
        #endif
    }

    private func scheduleGeometryRecording() {
        guard paper != nil, !restoringFrame else { return }
        pendingGeometryUpdate?.cancel()
        // Geometry is not displayed by SwiftUI. Avoid publishing the entire
        // document on every pixel of a drag or live resize.
        pendingGeometryUpdate = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { return }
            self?.recordGeometry()
        }
    }

    private func recordGeometry() {
        pendingGeometryUpdate?.cancel()
        pendingGeometryUpdate = nil
        guard paper != nil, !restoringFrame else { return }
        store.recordWindowFrame(paper.frame, collapsed: paperIsCollapsed)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === paper else { return true }
        shelvePaper()
        return false
    }

    func prepareToTerminate() -> Bool {
        commitMarkedText()
        recordGeometry()
        return store.loadError != nil || store.flush()
    }

    func dispose() {
        colorObservation = nil
        pendingGeometryUpdate?.cancel()
        paper.onActivate = nil
        paper.onRequestClose = nil
        paper.onToggleCollapsed = nil
        paper.onEndResize = nil
        paper.onBeginMove = nil
        paper.delegate = nil
        if let paperShadow { paper.removeChildWindow(paperShadow); paperShadow.orderOut(nil); paperShadow.close() }
        paper.orderOut(nil)
        paper.contentView = nil
        paper.close()
    }
}
