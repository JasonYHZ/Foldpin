import AppKit
import SwiftUI
import Foundation
import CoreGraphics
import Dispatch
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let languageSettings = LanguageSettings.shared
    let store = NoteStore(localizationBundle: LanguageSettings.shared.bundle)
    private var languageSubscription: AnyCancellable?
    private var localeObserver: NSObjectProtocol?
    private var menuObserver: NSObjectProtocol?
    private var paper: PaperPanel!
    private var paperShadow: NoteShadowWindow?
    private var edge: EdgePanel!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let shortcut = GlobalShortcut()
    private var restoringFrame = false
    private var paperIsCollapsed = false
    private var expandedMaximumSize = NSSize.zero
    private var pendingGeometryUpdate: Task<Void, Never>?
    private var previousApplication: NSRunningApplication?
    private var screenObserver: NSObjectProtocol?
    private(set) var shortcutChoice = UserDefaults.standard.integer(forKey: "captureShortcut")

    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemeSettings.shared.apply()
        createPaper()
        createEdge()
        createMenu()
        languageSubscription = languageSettings.$configuration.dropFirst().sink { [weak self] _ in
            // Published emits before the new value is stored. Update AppKit on
            // the next main-loop turn; SwiftUI observes the same configuration.
            DispatchQueue.main.async { self?.applyLanguage() }
        }
        localeObserver = NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.languageSettings.refresh() }
        }
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshApplicationMenu() }
        }
        DispatchQueue.main.async { [weak self] in self?.refreshApplicationMenu() }
        shortcut.onPress = { [weak self] in self?.togglePaper() }
        configureShortcut(shortcutChoice)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        if store.document.isShelved && store.loadError == nil {
            showEdge()
        } else {
            showPaper(focus: true)
        }
    }

    private var workingScreen: NSScreen {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func createPaper() {
        let screen = workingScreen.visibleFrame
        let initial = store.document.frame ?? NoteFrame(CGRect(x: screen.maxX - 452, y: screen.midY - 170, width: 360, height: 340))
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
        paper.onRequestClose = { [weak self] in self?.shelvePaper() }
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
            onShelve: { [weak self] in self?.shelvePaper() },
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

    private func createEdge() {
        edge = EdgePanel(contentRect: NSRect(x: 0, y: 0, width: 34, height: 84),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        edge.isReleasedWhenClosed = false
        edge.hidesOnDeactivate = false
        edge.level = .floating
        edge.isOpaque = false
        edge.backgroundColor = .clear
        edge.hasShadow = true
        edge.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
        edge.contentView = NSHostingView(rootView: EdgeView { [weak self] in self?.toggleShelf() })
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ShelfView(store: store, onOpen: { [weak self] in self?.showPaper(focus: true) }))
    }

    private func createMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Foldpin")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.setAccessibilityLabel(String(localized: "Foldpin menu bar", bundle: languageSettings.bundle))
        statusItem.button?.toolTip = String(localized: "Foldpin · Notes and Settings", bundle: languageSettings.bundle)
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard statusItem != nil else { return }
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self; menu.addItem(item); return item
        }
        _ = item(String(localized: "Open Note", bundle: languageSettings.bundle), #selector(openPaper))
        let collapse = item(store.isCollapsed ? String(localized: "Expand Note", bundle: languageSettings.bundle) : String(localized: "Collapse to One Line", bundle: languageSettings.bundle), #selector(toggleCollapsed))
        collapse.isEnabled = !store.document.isShelved && store.loadError == nil
        let shelve = item(String(localized: "Shelve Note", bundle: languageSettings.bundle), #selector(shelvePaper))
        shelve.isEnabled = !store.document.isShelved && store.loadError == nil
        let pin = item(String(localized: "Pin Note", bundle: languageSettings.bundle), #selector(togglePin))
        pin.state = store.document.isPinned ? .on : .off
        pin.isEnabled = store.loadError == nil
        menu.addItem(.separator())
        _ = item(String(localized: "Settings…", bundle: languageSettings.bundle), #selector(showSettings), key: ",")
        let parent = NSMenuItem(title: String(localized: "Show / Shelve Shortcut", bundle: languageSettings.bundle), action: nil, keyEquivalent: "")
        let choices = NSMenu()
        for choice in 0...1 {
            let child = NSMenuItem(title: GlobalShortcut.label(for: choice), action: #selector(changeShortcut(_:)), keyEquivalent: "")
            child.target = self; child.tag = choice; child.state = shortcutChoice == choice ? .on : .off
            choices.addItem(child)
        }
        parent.submenu = choices; menu.addItem(parent)
        if store.hotKeyWarning != nil {
            let warning = NSMenuItem(title: String(localized: "Shortcut unavailable. Choose another combination.", bundle: languageSettings.bundle), action: nil, keyEquivalent: "")
            warning.isEnabled = false; menu.addItem(warning)
        }
        menu.addItem(.separator())
        _ = item(String(localized: "Quit Foldpin", bundle: languageSettings.bundle), #selector(quit), key: "q")
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    private func applyLanguage() {
        store.localizationBundle = languageSettings.bundle
        paper.title = String(localized: "Foldpin Note", bundle: languageSettings.bundle)
        statusItem.button?.setAccessibilityLabel(String(localized: "Foldpin menu bar", bundle: languageSettings.bundle))
        statusItem.button?.toolTip = String(localized: "Foldpin · Notes and Settings", bundle: languageSettings.bundle)
        rebuildMenu()
        refreshApplicationMenu()
    }

    private func refreshApplicationMenu() {
        if let menu = NSApp.mainMenu {
            ApplicationMenuLocalization.update(menu, bundle: languageSettings.bundle)
        }
    }

    @objc func openPaper() {
        if store.isCollapsed { toggleCollapsed() }
        showPaper(focus: true)
    }

    @objc func showSettings() {
        popover.close()
        // Invoke SwiftUI's actual Settings menu command, keeping every entry point
        // on the same Settings scene without deprecated private selector strings.
        DispatchQueue.main.async {
            NSApp.activate()
            guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
                  let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) else { return }
            appMenu.performActionForItem(at: index)
        }
    }

    func showPaper(focus: Bool) {
        // A menu or shortcut can arrive before the last move has been recorded.
        if pendingGeometryUpdate != nil { recordGeometry() }
        if focus, let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = frontmost
        }
        popover.close()
        edge.orderOut(nil)
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
        rebuildMenu()
    }

    private func activatePaper() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = frontmost
        }
        NSApp.activate()
        paper.makeKey()
        paper.makeMain()
    }

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
        rebuildMenu()
    }

    private func revealError() {
        guard paperIsCollapsed else { return }
        recordGeometry()
        store.setCollapsed(false)
        applyPaperPresentation()
        if paper.isVisible { paperShadow?.show(below: paper) }
        rebuildMenu()
    }

    @objc func shelvePaper() {
        guard store.loadError == nil else { return }
        commitMarkedText()
        recordGeometry()
        store.setShelved(true)
        guard store.flush() else {
            store.setShelved(false)
            revealError()
            return
        }
        let hadFocus = paper.isKeyWindow
        paperShadow?.orderOut(nil)
        paper.orderOut(nil)
        showEdge()
        if hadFocus { previousApplication?.activate() }
        rebuildMenu()
    }

    private func showEdge() {
        let rect = paper.frame
        let screen = NSScreen.screens.max { intersectionArea(rect, $0.visibleFrame) < intersectionArea(rect, $1.visibleFrame) } ?? workingScreen
        let visible = screen.visibleFrame
        edge.setFrameOrigin(NSPoint(x: visible.maxX - 34, y: visible.midY - 42))
        edge.orderFrontRegardless()
    }

    private func intersectionArea(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private func toggleShelf() {
        if popover.isShown { popover.close(); return }
        guard let view = edge.contentView else { return }
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minX)
    }

    private func togglePaper() {
        if store.isCollapsed { openPaper() }
        else if paper.isVisible && paper.isKeyWindow { shelvePaper() }
        else { showPaper(focus: true) }
    }

    @objc func togglePin() {
        store.setPinned(!store.document.isPinned)
        paper.level = store.document.isPinned ? .floating : .normal
        if paper.isVisible { paperShadow?.show(below: paper) }
        rebuildMenu()
    }

    @objc private func changeShortcut(_ sender: NSMenuItem) { configureShortcut(sender.tag) }

    func configureShortcut(_ choice: Int) {
        shortcutChoice = choice == 1 ? 1 : 0
        UserDefaults.standard.set(shortcutChoice, forKey: "captureShortcut")
        let status = shortcut.register(choice: shortcutChoice)
        store.shortcutLabel = GlobalShortcut.label(for: shortcutChoice)
        store.hotKeyStatus = status
        rebuildMenu()
    }

    private func retryLoad() {
        // Keep presentation and remembered geometry in sync with the reloaded file.
        store.reload()
        if store.loadError == nil {
            applyPaperPresentation()
            if store.document.isShelved {
                paperShadow?.orderOut(nil)
                paper.orderOut(nil)
                showEdge()
            } else { showPaper(focus: true) }
        }
        rebuildMenu()
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

    private func screensChanged() {
        let frame = NoteFrame(paper.frame).fitted(to: NSScreen.screens.map(\.visibleFrame), fallback: workingScreen.visibleFrame,
                                                minimumSize: minimumPaperSize)
        setFrame(frame); recordGeometry()
        if store.document.isShelved { popover.close(); showEdge() }
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPaper(); return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store.loadError == nil else { return .terminateNow }
        recordGeometry()
        guard store.flush() else {
            showPaper(focus: true)
            let alert = NSAlert()
            alert.messageText = String(localized: "Your note could not be saved", bundle: languageSettings.bundle)
            alert.informativeText = String(localized: "Your text is still in the window. Retry saving before quitting Foldpin.", bundle: languageSettings.bundle)
            alert.addButton(withTitle: String(localized: "Back to Note", bundle: languageSettings.bundle))
            alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        pendingGeometryUpdate?.cancel()
        shortcut.stop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let localeObserver { NotificationCenter.default.removeObserver(localeObserver) }
        if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) }
        languageSubscription?.cancel()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

final class PaperPanel: NSPanel {
    var onActivate: (() -> Void)?
    var onToggleCollapsed: (() -> Void)?
    var onRequestClose: (() -> Void)?
    var onEndResize: (() -> Void)?
    private var resizeSession: ResizeSession?

    private struct ResizeSession {
        let edges: NoteResizeEdges
        let initialFrame: NSRect
        let initialPointer: NSPoint
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if let session = resizeSession,
           event.type == .leftMouseDragged || event.type == .leftMouseUp {
            let pointer = convertPoint(toScreen: event.locationInWindow)
            let delta = NSSize(width: pointer.x - session.initialPointer.x,
                               height: pointer.y - session.initialPointer.y)
            let nextFrame = session.edges.resizing(session.initialFrame, by: delta,
                                                    minimum: minSize, maximum: maxSize)
            if nextFrame != frame { setFrame(nextFrame, display: true) }
            if event.type == .leftMouseUp { finishResize() }
            return
        }
        // Explicit interaction should make this the front application's focused
        // window; passive display still uses the nonactivating panel behavior.
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            onActivate?()
        }
        if event.type == .leftMouseDown, let surface = contentView as? NoteWindowSurface {
            let edges = surface.resizeEdges(at: event.locationInWindow)
            if !edges.isEmpty {
                resizeSession = ResizeSession(edges: edges, initialFrame: frame,
                                              initialPointer: convertPoint(toScreen: event.locationInWindow))
                return
            }
        }
        // Handle the titlebar before SwiftUI / glass dispatch can consume the
        // empty representable's mouse-down. Keep the original system drag event.
        if event.type == .leftMouseDown,
           let surface = contentView as? NoteWindowSurface,
           let dragRegion = surface.titlebarDragRegion(at: event.locationInWindow) {
            dragRegion.mouseDown(with: event)
            return
        }
        super.sendEvent(event)
    }

    private func finishResize() {
        guard resizeSession != nil else { return }
        resizeSession = nil
        onEndResize?()
    }

    override func resignKey() {
        finishResize()
        super.resignKey()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard isKeyWindow, event.type == .keyDown, modifiers == .command else {
            return super.performKeyEquivalent(with: event)
        }
        // Route shortcuts only in this focused paper, including its collapsed
        // strip. Settings and other apps keep their native window commands.
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "m" where onToggleCollapsed != nil:
            if !event.isARepeat { onToggleCollapsed?() }
            return true
        case "w" where onRequestClose != nil:
            if !event.isARepeat { performClose(nil) }
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func performClose(_ sender: Any?) {
        // A borderless paper has no native close button. Use the same guarded
        // save-and-shelve path as its custom close button and never delete data.
        if let onRequestClose { onRequestClose() }
        else { super.performClose(sender) }
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(NSWindow.performClose(_:)), onRequestClose != nil {
            return isVisible
        }
        return super.validateMenuItem(menuItem)
    }
}

final class EdgePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
