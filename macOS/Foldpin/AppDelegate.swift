import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let languageSettings = LanguageSettings.shared
    let library = NoteLibrary()
    private var windows: [UUID: PaperWindowController] = [:]
    private var lastActiveID: UUID?
    private var previousApplication: NSRunningApplication?
    private var languageSubscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var edge: EdgePanel!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let shortcut = GlobalShortcut()
    private var shortcutStatus: Int32 = 0
    private(set) var shortcutChoice = UserDefaults.standard.integer(forKey: "captureShortcut")

    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemeSettings.shared.apply()
        createEdge()
        createMenu()
        applyLanguage()
        languageSubscription = languageSettings.$configuration.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyLanguage() }
        }
        observe(NSLocale.currentLocaleDidChangeNotification) { [weak self] in self?.languageSettings.refresh() }
        observe(NSMenu.didBeginTrackingNotification) { [weak self] in self?.refreshApplicationMenu() }
        observe(NSApplication.didChangeScreenParametersNotification) { [weak self] in
            guard let self else { return }
            for window in windows.values { window.screensChanged() }
            updateEdge()
        }
        shortcut.onPress = { [weak self] in self?.togglePaper() }
        configureShortcut(shortcutChoice)
        for entry in library.entries where !entry.store.document.isShelved || entry.store.loadError != nil {
            controller(for: entry).showPaper(focus: false)
            lastActiveID = entry.id
        }
        updateEdge()
        if library.failure != nil { DispatchQueue.main.async { [weak self] in self?.showShelf() } }
    }

    private func observe(_ name: Notification.Name, action: @escaping @MainActor () -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        })
    }

    private var workingScreen: NSScreen {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private var currentPaper: PaperWindowController? {
        windows.values.first { $0.isKey } ?? lastActiveID.flatMap { windows[$0] }
    }

    private func controller(for entry: NoteLibrary.Entry, initialFrame: NSRect? = nil) -> PaperWindowController {
        if let existing = windows[entry.id] { return existing }
        entry.store.shortcutLabel = GlobalShortcut.label(for: shortcutChoice)
        entry.store.hotKeyStatus = shortcutStatus
        let window = PaperWindowController(entry: entry, initialFrame: initialFrame)
        window.onActivate = { [weak self] id in
            guard let self else { return }
            if let frontmost = NSWorkspace.shared.frontmostApplication,
               frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApplication = frontmost }
            lastActiveID = id
            rebuildMenu()
        }
        window.onStateChange = { [weak self] in self?.updateEdge(); self?.rebuildMenu() }
        window.onShelved = { [weak self] id, hadFocus in
            guard let self, hadFocus else { return }
            if let next = library.entries.reversed().compactMap({ self.windows[$0.id] }).first(where: { $0.id != id && $0.isVisible }) {
                next.showPaper(focus: true)
            } else { previousApplication?.activate() }
        }
        windows[entry.id] = window
        return window
    }

    @objc func newPaper() {
        guard let entry = library.createNote() else { showShelf(); rebuildMenu(); return }
        let screen = workingScreen.visibleFrame
        let offset = CGFloat(windows.values.filter(\.isVisible).count % 8) * 24
        let frame = NSRect(x: screen.maxX - 452 - offset, y: screen.midY - 170 - offset, width: 360, height: 340)
        popover.close()
        controller(for: entry, initialFrame: frame).showPaper(focus: true)
    }

    private func openPaper(_ id: UUID) {
        guard let entry = library.entry(id) else { return }
        popover.close()
        controller(for: entry).showPaper(focus: true)
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
        edge.contentView = NSHostingView(rootView: EdgeView(library: library) { [weak self] in self?.toggleShelf() })
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ShelfView(library: library,
            onOpen: { [weak self] in self?.openPaper($0) }, onNew: { [weak self] in self?.newPaper() },
            onRetry: { [weak self] in self?.retryLibrary() }))
    }

    private func updateEdge() {
        guard edge != nil else { return }
        let visible = workingScreen.visibleFrame
        edge.setFrameOrigin(NSPoint(x: visible.maxX - 34, y: visible.midY - 42))
        if library.failure != nil || library.entries.contains(where: { $0.store.document.isShelved }) || windows.values.allSatisfy({ !$0.isVisible }) {
            edge.orderFrontRegardless()
        } else { edge.orderOut(nil) }
    }

    private func toggleShelf() {
        if popover.isShown { popover.close(); return }
        guard let view = edge.contentView else { return }
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minX)
    }

    @objc func showShelf() {
        guard let button = statusItem?.button else { return }
        popover.close()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func retryLibrary() {
        library.reload()
        applyLanguage()
        for entry in library.entries where windows[entry.id] == nil && !entry.store.document.isShelved {
            controller(for: entry).showPaper(focus: false)
        }
        updateEdge()
    }

    private func createMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Foldpin")
        statusItem.button?.image?.isTemplate = true
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard statusItem != nil else { return }
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
            let value = NSMenuItem(title: title, action: action, keyEquivalent: key)
            value.target = self; menu.addItem(value); return value
        }
        item(String(localized: "New Note", bundle: languageSettings.bundle), #selector(newPaper), key: "n").isEnabled = library.canCreate
        _ = item(String(localized: "Open Shelf", bundle: languageSettings.bundle), #selector(showShelf))
        menu.addItem(.separator())
        let current = currentPaper
        let enabled = current?.isVisible == true && current?.store.loadError == nil
        item(current?.store.isCollapsed == true ? String(localized: "Expand Note", bundle: languageSettings.bundle) : String(localized: "Collapse to One Line", bundle: languageSettings.bundle), #selector(toggleCollapsed)).isEnabled = enabled
        item(String(localized: "Shelve Note", bundle: languageSettings.bundle), #selector(shelvePaper)).isEnabled = enabled
        let pin = item(String(localized: "Pin Note", bundle: languageSettings.bundle), #selector(togglePin))
        pin.state = current?.store.document.isPinned == true ? .on : .off
        pin.isEnabled = enabled
        let color = NSMenuItem(title: String(localized: "Note Color", bundle: languageSettings.bundle), action: nil, keyEquivalent: "")
        color.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
        color.submenu = current?.makeColorMenu()
        color.isEnabled = enabled
        menu.addItem(color)
        item(String(localized: "Shelve All Notes", bundle: languageSettings.bundle), #selector(shelveAll)).isEnabled = windows.values.contains { $0.isVisible }
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
        if shortcutStatus != 0 {
            let warning = NSMenuItem(title: String(localized: "Shortcut unavailable. Choose another combination.", bundle: languageSettings.bundle), action: nil, keyEquivalent: "")
            warning.isEnabled = false; menu.addItem(warning)
        }
        menu.addItem(.separator())
        _ = item(String(localized: "Quit Foldpin", bundle: languageSettings.bundle), #selector(quit), key: "q")
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    private func applyLanguage() {
        for entry in library.entries { entry.store.localizationBundle = languageSettings.bundle }
        for window in windows.values { window.applyLanguage() }
        statusItem?.button?.setAccessibilityLabel(String(localized: "Foldpin menu bar", bundle: languageSettings.bundle))
        statusItem?.button?.toolTip = String(localized: "Foldpin · Notes and Settings", bundle: languageSettings.bundle)
        rebuildMenu()
        refreshApplicationMenu()
    }

    private func refreshApplicationMenu() {
        if let menu = NSApp.mainMenu { ApplicationMenuLocalization.update(menu, bundle: languageSettings.bundle) }
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

    private func togglePaper() {
        if let current = currentPaper {
            if current.isKey && !current.store.isCollapsed { current.shelvePaper() }
            else { current.openExpanded() }
        } else if let entry = library.entries.last { controller(for: entry).openExpanded() }
        else { newPaper() }
    }

    @objc private func toggleCollapsed() { currentPaper?.toggleCollapsed() }
    @objc private func togglePin() { currentPaper?.togglePin() }
    @objc private func shelvePaper() { _ = currentPaper?.shelvePaper() }
    @objc private func shelveAll() {
        var failed: PaperWindowController?
        for window in windows.values where window.isVisible {
            if !window.shelvePaper(restoringFocus: false) { failed = window }
        }
        if let failed { failed.showPaper(focus: true) }
        else { previousApplication?.activate() }
    }

    @objc private func changeShortcut(_ sender: NSMenuItem) { configureShortcut(sender.tag) }
    func configureShortcut(_ choice: Int) {
        shortcutChoice = choice == 1 ? 1 : 0
        UserDefaults.standard.set(shortcutChoice, forKey: "captureShortcut")
        shortcutStatus = shortcut.register(choice: shortcutChoice)
        for entry in library.entries {
            entry.store.shortcutLabel = GlobalShortcut.label(for: shortcutChoice)
            entry.store.hotKeyStatus = shortcutStatus
        }
        rebuildMenu()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let current = currentPaper { current.showPaper(focus: true) } else { showShelf() }
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for entry in library.entries {
            let saved = windows[entry.id]?.prepareToTerminate() ?? (entry.store.loadError != nil || entry.store.flush())
            if !saved {
                controller(for: entry).showPaper(focus: true)
                let alert = NSAlert()
                alert.messageText = String(localized: "Your note could not be saved", bundle: languageSettings.bundle)
                alert.informativeText = String(localized: "Your text is still in the window. Retry saving before quitting Foldpin.", bundle: languageSettings.bundle)
                alert.addButton(withTitle: String(localized: "Back to Note", bundle: languageSettings.bundle))
                alert.runModal()
                return .terminateCancel
            }
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        shortcut.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        languageSubscription?.cancel()
        for window in windows.values { window.dispose() }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
