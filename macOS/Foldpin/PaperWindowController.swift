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
    private var actionsPanel: NoteActionsPanel?
    private var copyFeedbackTask: Task<Void, Never>?
    private var languageSettings: LanguageSettings { .shared }
    #if DEBUG
    private static let geometryLog = Logger(subsystem: "Foldpin", category: "WindowGeometry")
    #endif
    var onActivate: ((UUID) -> Void)?
    var onStateChange: (() -> Void)?
    var onShelved: ((UUID, Bool) -> Void)?
    var onApplicationAction: ((NoteAction) -> Void)?
    var canPerformApplicationAction: ((NoteAction) -> Bool)?
    var onDelete: (() -> Void)?

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
        paper.onAction = { [weak self] in self?.performAction($0) }
        paper.onShortcutHints = { [weak state = titlebarState] in state?.setShortcutHints($0) }
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
            onColorMenu: { [weak self] in self?.makeColorMenu() },
            onActions: { [weak self] in self?.performAction(.actions) }))
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

    private func actionIsEnabled(_ action: NoteAction) -> Bool {
        guard paper.isVisible, store.document.deletedAt == nil else { return false }
        if action == .actions { return true }
        if action == .duplicateNote { return store.loadError == nil && canPerformApplicationAction?(action) != false }
        if action.isPaperAction { return store.loadError == nil }
        return canPerformApplicationAction?(action) ?? false
    }

    func performAction(_ action: NoteAction) {
        guard actionIsEnabled(action) else { NSSound.beep(); return }
        if action != .actions, actionsPanel?.isShown == true { actionsPanel?.close(restoringFocus: true) }
        if let color = action.noteColor {
            store.setColor(color)
            onStateChange?()
            return
        }
        switch action {
        case .actions:
            if actionsPanel?.isShown == true {
                actionsPanel?.close(restoringFocus: true)
                return
            }
            paper.cancelShortcutHints()
            titlebarState.isActionsPresented = true
            let menu = actionsPanel ?? NoteActionsPanel()
            actionsPanel = menu
            menu.onClose = { [weak state = titlebarState] in state?.isActionsPresented = false }
            menu.show(in: paper, anchorView: titlebarState.actionsAnchor, store: store,
                         isEnabled: { [weak self] in self?.actionIsEnabled($0) ?? false },
                         perform: { [weak self] in self?.performAction($0) })
        case .pin: togglePin()
        case .collapse: toggleCollapsed()
        case .shelve: shelvePaper()
        case .icon: titlebarState.iconRequest += 1
        case .copyAll:
            commitMarkedText()
            guard audioEditor?.prepareAudioForHiding() != false else { return }
            do {
                try NoteClipboard.copy(store.document.content, file: store.file)
                copyFeedbackTask?.cancel()
                titlebarState.copiedAll = true
                copyFeedbackTask = Task { [weak state = titlebarState] in
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    state?.copiedAll = false
                }
            }
            catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "Could not copy all content", bundle: languageSettings.bundle)
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: paper)
            }
        case .deleteNote: onDelete?()
        case .duplicateNote:
            commitMarkedText()
            onApplicationAction?(action)
        case .color:
            guard let view = paper.contentView else { return }
            let point = NSPoint(x: max(16, view.bounds.maxX - 170),
                                y: view.isFlipped ? NoteLayout.headerHeight : view.bounds.maxY - NoteLayout.headerHeight)
            makeColorMenu().popUp(positioning: nil, at: point, in: view)
        default: onApplicationAction?(action)
        }
    }

    func makeColorMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Note Color", bundle: languageSettings.bundle))
        menu.autoenablesItems = false
        for color in NoteColor.allCases {
            let item = NSMenuItem(title: color.title(bundle: languageSettings.bundle),
                                  action: #selector(changeColor(_:)), keyEquivalent: "")
            item.target = self
            if let action = NoteAction.colors.first(where: { $0.noteColor == color }) {
                item.keyEquivalent = action.key
                item.keyEquivalentModifierMask = action.modifiers
            }
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
        guard store.document.deletedAt == nil else { return }
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

    func activatePaper() {
        onActivate?(id)
        if !NSApp.isActive { NSApp.activate() }
        paper.makeKeyAndOrderFront(nil)
        paper.makeMain()
    }

    func windowDidBecomeKey(_ notification: Notification) { onActivate?(id) }

    private var audioEditor: PaperTextView? {
        func find(_ view: NSView) -> PaperTextView? {
            if let editor = view as? PaperTextView { return editor }
            for child in view.subviews { if let editor = find(child) { return editor } }
            return nil
        }
        return paper.contentView.flatMap(find)
    }

    private func commitMarkedText() {
        audioEditor?.prepareImageEditingForHiding()
        if let editor = paper.firstResponder as? NSTextView, editor.hasMarkedText() {
            editor.unmarkText()
            (editor as? PaperTextView)?.commitContent()
        }
    }

    @objc func toggleCollapsed() {
        guard store.loadError == nil else { return }
        actionsPanel?.close(restoringFocus: true)
        commitMarkedText()
        recordGeometry()
        let collapsing = !store.isCollapsed
        if collapsing, audioEditor?.prepareAudioForHiding() == false { return }
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
        if actionsPanel?.isShown == true { actionsPanel?.close(restoringFocus: true) }
        commitMarkedText()
        recordGeometry()
        guard audioEditor?.prepareAudioForHiding() != false else { return false }
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
        guard store.loadError == nil else { return }
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

    var canArrange: Bool {
        isVisible && !store.document.isShelved && store.document.deletedAt == nil
            && store.loadError == nil && !paper.isResizingByMouse
    }

    @discardableResult func moveForArrangement(to origin: CGPoint) -> Bool {
        guard canArrange else { return false }
        actionsPanel?.close(restoringFocus: true)
        recordGeometry()
        let target = CGRect(origin: origin, size: paper.frame.size)
        guard store.saveArrangedWindowFrame(target, collapsed: paperIsCollapsed) else { return false }
        setFrame(target)
        (paper.contentView as? NoteWindowSurface)?.refreshPointerPresence()
        return true
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
        actionsPanel?.close()
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
        actionsPanel?.close()
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
        guard audioEditor?.prepareAudioForHiding() != false else { return false }
        recordGeometry()
        return store.loadError != nil || store.flush()
    }

    func hideDeletedPaper() {
        actionsPanel?.close()
        pendingGeometryUpdate?.cancel()
        pendingGeometryUpdate = nil
        paperShadow?.orderOut(nil)
        paper.orderOut(nil)
        titlebarState.setPointerInside(false)
    }

    func dispose() {
        audioEditor?.stopAudio()
        copyFeedbackTask?.cancel()
        actionsPanel?.close()
        actionsPanel = nil
        paper.cancelShortcutHints()
        paper.onAction = nil
        paper.onShortcutHints = nil
        onApplicationAction = nil
        canPerformApplicationAction = nil
        onDelete = nil
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
