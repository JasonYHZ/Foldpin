import AppKit
import SwiftUI

/// One retained editor and undo history per note, including while shelved.
@MainActor
final class PaperWindowController: NSObject, NSWindowDelegate {
    let id: UUID
    let store: NoteStore
    private(set) var paper: PaperPanel!
    private var paperShadow: NoteShadowWindow?
    private var restoringFrame = false
    private var paperIsCollapsed = false
    private var expandedMaximumSize = NSSize.zero
    private var pendingGeometryUpdate: Task<Void, Never>?
    private var languageSettings: LanguageSettings { .shared }
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
        paper = PaperPanel(contentRect: frame, styleMask: [.borderless, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        paper.title = String(localized: "Foldpin Note", bundle: languageSettings.bundle)
        // This panel is the document window, not an auxiliary dialog. Window
        // managers discover it through the standard accessibility window role.
        paper.setAccessibilitySubrole(.standardWindow)
        paper.onActivate = { [weak self] in self?.activatePaper() }
        paper.onToggleCollapsed = { [weak self] in self?.toggleCollapsed() }
        paper.onRequestClose = { [weak self] in _ = self?.shelvePaper() }
        paper.onEndResize = { [weak self] in self?.recordGeometry() }
        paper.isReleasedWhenClosed = false
        paper.isMovable = true
        // Only the explicit header drag region initiates a native window drag.
        paper.isMovableByWindowBackground = false
        paper.hidesOnDeactivate = false
        paper.becomesKeyOnlyIfNeeded = true
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
        let hosting = TransparentNoteHostingView(rootView: ContentView(store: store,
            onPin: { [weak self] in self?.togglePin() },
            onCollapse: { [weak self] in self?.toggleCollapsed() },
            onShelve: { [weak self] in _ = self?.shelvePaper() },
            onRetryLoad: { [weak self] in self?.retryLoad() },
            onRevealError: { [weak self] in self?.revealError() }))
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        paper.contentView = NoteWindowSurface(content: hosting)
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
        onStateChange?()
    }

    func openExpanded() {
        if store.isCollapsed { toggleCollapsed() }
        showPaper(focus: true)
    }

    private func activatePaper() {
        onActivate?(id)
        NSApp.activate()
        paper.makeKey()
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

    private func applyPaperPresentation() {
        let expanded = store.document.frame?.rect ?? paper.frame
        paperIsCollapsed = store.isCollapsed
        let visible = NoteLayout.visibleFrame(expanded: expanded, collapsed: paperIsCollapsed)
        let fitted = NoteFrame(visible).fitted(to: NSScreen.screens.map(\.visibleFrame),
                                             fallback: workingScreen.visibleFrame,
                                             minimumSize: minimumPaperSize)
        restoringFrame = true
        paper.contentMaxSize = expandedMaximumSize
        paper.contentMinSize = minimumPaperSize
        if paperIsCollapsed {
            paper.contentMaxSize = NSSize(width: expandedMaximumSize.width, height: NoteLayout.headerHeight)
        }
        setFrame(fitted)
        recordGeometry()
    }

    func screensChanged() {
        let frame = NoteFrame(paper.frame).fitted(to: NSScreen.screens.map(\.visibleFrame), fallback: workingScreen.visibleFrame,
                                                minimumSize: minimumPaperSize)
        setFrame(frame); recordGeometry()
        onStateChange?()
    }

    func windowDidMove(_ notification: Notification) { scheduleGeometryRecording() }
    func windowDidResize(_ notification: Notification) {
        paperShadow?.updateFrame(for: paper)
        scheduleGeometryRecording()
    }
    func windowDidEndLiveResize(_ notification: Notification) { recordGeometry() }

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
        pendingGeometryUpdate?.cancel()
        paper.onActivate = nil
        paper.onRequestClose = nil
        paper.onToggleCollapsed = nil
        paper.onEndResize = nil
        paper.delegate = nil
        if let paperShadow { paper.removeChildWindow(paperShadow); paperShadow.orderOut(nil); paperShadow.close() }
        paper.orderOut(nil)
        paper.contentView = nil
        paper.close()
    }
}
