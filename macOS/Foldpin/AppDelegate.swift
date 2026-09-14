import AppKit
import SwiftUI
import Combine
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let languageSettings = LanguageSettings.shared
    let storage = LibraryLocationController()
    var library: NoteLibrary { storage.library }
    private var libraryWindows: [ObjectIdentifier: [UUID: PaperWindowController]] = [:]
    private var windows: [UUID: PaperWindowController] = [:]
    private var lastActiveID: UUID?
    private var lastArrangement: [NoteArrangement.Placement] = []
    private var previousApplication: NSRunningApplication?
    private var languageSubscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var edge: EdgePanel!
    private var statusItem: NSStatusItem!
    private var shelfWindow: ShelfPreviewWindow?
    private let shortcut = GlobalShortcut()
    private let shortcutSettings = ShortcutSettings.shared
    private var localShortcutMonitor: Any?
    private let quickRecording = QuickRecordingFlow()
    private var recordingSaveRetryID: UUID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        storage.prepare = { [weak self] in
            guard let self else { return }
            guard LibraryFileActivity.exports == 0, !AudioBlockModel.requestingRecording,
                  windows.values.allSatisfy({ !$0.session.host.editor.hasPendingLibraryFileWork }) else { throw LibraryStorageError.busy }
            guard shelfWindow?.finish() != false else { throw LibraryStorageError.unavailable }
            for controller in windows.values {
                if controller.store.loadError != nil && !controller.store.isDirty { continue }
                guard controller.session.prepareToLeave(), controller.prepareToTerminate() else { throw LibraryStorageError.unavailable }
                controller.session.host.editor.releaseMediaForLibraryChange()
            }
            for entry in library.entries + library.deletedEntries {
                if entry.store.loadError == nil || entry.store.isDirty {
                    guard entry.store.flush() else { throw LibraryStorageError.unavailable }
                }
            }
        }
        storage.didSwitch = { [weak self] old, relocating in
            guard let self else { return }
            let shelfVisible = shelfWindow?.window.isVisible == true
            shelfWindow?.window.orderOut(nil); shelfWindow = nil
            if !relocating {
                for controller in windows.values { controller.hideDeletedPaper() }
                libraryWindows[ObjectIdentifier(old)] = windows
                windows = libraryWindows[ObjectIdentifier(library)] ?? [:]
                lastActiveID = nil; lastArrangement = []
            }
            for entry in library.entries where !entry.store.document.isShelved {
                controller(for: entry).showPaper(focus: false)
            }
            applyLanguage(); updateEdge(); rebuildMenu()
            if shelfVisible { showShelf() }
        }
        storage.willRefresh = { [weak self] in
            guard let self else { return false }
            guard windows.values.allSatisfy({ !$0.session.host.editor.hasPendingLibraryWork && !$0.session.host.editor.hasMarkedText()
                && $0.session.host.editor.tableCellEditor?.hasMarkedText() != true }) else { return false }
            return (library.entries + library.deletedEntries).allSatisfy { !$0.store.isDirty || $0.store.flush() }
        }
        storage.didRefresh = { [weak self] in
            guard let self else { return }
            for controller in windows.values {
                if controller.store.document.deletedAt != nil || library.path.snapshot.notes[controller.id]?.payload == nil {
                    controller.hideDeletedPaper()
                }
            }
            for controller in windows.values { controller.session.synchronizeContentFromStore() }
            shelfWindow?.collections.reload()
            updateEdge(); rebuildMenu()
        }
        storage.resourcesArrived = { [weak self] ids in
            for id in ids { self?.windows[id]?.session.host.editor.refreshCloudResources() }
        }
        storage.start()
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
        configureShortcuts()
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
        entry.store.shortcutLabel = shortcutSettings.binding(GlobalShortcutAction.toggleNotes).keycaps.joined()
        entry.store.hotKeyStatus = shortcutSettings.globalError == nil ? 0 : -1
        let window = PaperWindowController(entry: entry, initialFrame: initialFrame)
        window.onActivate = { [weak self] id in
            guard let self else { return }
            if let frontmost = NSWorkspace.shared.frontmostApplication,
               frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApplication = frontmost }
            lastActiveID = id
            rebuildMenu()
        }
        window.onStateChange = { [weak self] in self?.updateEdge(); self?.rebuildMenu() }
        window.canPerformApplicationAction = { [weak self] action in
            guard let self else { return false }
            if action == .newNote || action == .duplicateNote { return library.canCreate }
            if action == .arrange { return windows.values.contains { $0.canArrange } }
            if action == .undoArrangement { return canUndoArrangement }
            if action == .shelveAll { return windows.values.contains { $0.isVisible } }
            return true
        }
        window.onApplicationAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .newNote: newPaper()
            case .duplicateNote: duplicatePaper(entry.id)
            case .shelf: showShelf()
            case .arrange: arrangePapers()
            case .undoArrangement: undoArrangement()
            case .shelveAll: shelveAll()
            case .settings: showSettings()
            case .captureShortcut:
                shortcutSettings.showShortcuts = true; showSettings()
            default: break
            }
        }
        window.onDelete = { [weak self] in self?.deletePaper(entry.id) }
        window.onShelved = { [weak self] id, hadFocus in
            guard let self, hadFocus else { return }
            if let next = library.entries.reversed().compactMap({ self.windows[$0.id] }).first(where: { $0.id != id && $0.isVisible }) {
                next.showPaper(focus: true)
            } else { previousApplication?.activate() }
        }
        windows[entry.id] = window
        return window
    }

    private func deletePaper(_ id: UUID) {
        guard let window = windows[id], window.prepareToTerminate(), library.deleteNote(id) else { return }
        let hadFocus = window.isKey
        window.hideDeletedPaper()
        if lastActiveID == id { lastActiveID = nil }
        updateEdge(); rebuildMenu()
        if hadFocus {
            if let next = library.entries.reversed().compactMap({ windows[$0.id] }).first(where: \.isVisible) {
                next.showPaper(focus: true)
            } else { previousApplication?.activate() }
        }
    }

    private func duplicatePaper(_ id: UUID) {
        guard let source = windows[id], source.prepareToTerminate() else { return }
        guard let copy = library.duplicateNote(id) else { showShelf(); rebuildMenu(); return }
        controller(for: copy).showPaper(focus: true)
        updateEdge(); rebuildMenu()
    }

    private func restorePaper(_ id: UUID) {
        guard let entry = library.restoreNote(id) else { return }
        controller(for: entry).showPaper(focus: true)
        updateEdge(); rebuildMenu()
    }

    @objc func newPaper() {
        guard let entry = library.createNote() else { showShelf(); rebuildMenu(); return }
        let screen = workingScreen.visibleFrame
        let offset = CGFloat(windows.values.filter(\.isVisible).count % 8) * 24
        let frame = NSRect(x: screen.maxX - 452 - offset, y: screen.midY - 170 - offset, width: 360, height: 340)
        controller(for: entry, initialFrame: frame).showPaper(focus: true)
    }

    private func openPaper(_ id: UUID) {
        guard let entry = library.entry(id) else { return }
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

    }

    private func updateEdge() {
        // Temporarily hidden while the shelf is being redesigned. Keep every
        // lifecycle update from revealing it; menu and shortcut access remain.
        edge?.orderOut(nil)
    }

    private func toggleShelf() { showShelf() }

    @objc func showShelf() {
        if shelfWindow == nil {
            shelfWindow = ShelfPreviewWindow(library: library,
                resolve: { [weak self] id in
                    guard let self, let entry = library.entry(id) else { return nil }
                    return controller(for: entry)
                }, onNew: { [weak self] in self?.newPaper() },
                onRetry: { [weak self] in self?.retryLibrary() },
                onRestore: { [weak self] in self?.restorePaper($0) },
                existingController: { [weak self] in self?.windows[$0] },
                onPermanentlyDeleted: { [weak self] id in
                    guard let self else { return }
                    windows.removeValue(forKey: id)
                    if lastActiveID == id { lastActiveID = nil }
                    updateEdge(); rebuildMenu()
                })
        }
        shelfWindow?.show()
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
        func item(_ title: String, _ action: Selector, key: String = "", command: NoteAction? = nil) -> NSMenuItem {
            let value = NSMenuItem(title: title, action: action, keyEquivalent: key)
            if let command {
                value.keyEquivalent = command.activeKey
                value.keyEquivalentModifierMask = command.activeModifiers
            }
            value.target = self; menu.addItem(value); return value
        }
        item(String(localized: "New Note", bundle: languageSettings.bundle), #selector(newPaper), command: .newNote).isEnabled = library.canCreate
        _ = item(String(localized: "Open Shelf", bundle: languageSettings.bundle), #selector(showShelf), command: .shelf)
        menu.addItem(.separator())
        item(NoteAction.arrange.title(bundle: languageSettings.bundle), #selector(arrangePapers), command: .arrange).isEnabled = windows.values.contains { $0.canArrange }
        if !lastArrangement.isEmpty {
            item(NoteAction.undoArrangement.title(bundle: languageSettings.bundle), #selector(undoArrangement), command: .undoArrangement).isEnabled = canUndoArrangement
        }
        let visiblePapers = windows.values.filter { $0.isVisible && $0.store.loadError == nil }
        item(String(localized: "Collapse All Notes", bundle: languageSettings.bundle), #selector(collapseAll)).isEnabled = visiblePapers.contains { !$0.store.isCollapsed }
        item(String(localized: "Expand All Notes", bundle: languageSettings.bundle), #selector(expandAll)).isEnabled = visiblePapers.contains { $0.store.isCollapsed }
        item(String(localized: "Shelve All Notes", bundle: languageSettings.bundle), #selector(shelveAll), command: .shelveAll).isEnabled = windows.values.contains { $0.isVisible }
        menu.addItem(.separator())
        _ = item(String(localized: "Status Menu Settings", bundle: languageSettings.bundle), #selector(showSettings), key: ",")
        _ = item(String(localized: "Quit", bundle: languageSettings.bundle), #selector(quit), key: "q")
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
        // SwiftUI owns the main menu; install these app-wide commands in its
        // native Window menu, retaining AppKit's live action validation.
        guard let menu = NSApp.windowsMenu else { return }
        let identifier = NSUserInterfaceItemIdentifier("foldpin.arrangeDesktopNotes")
        if !menu.items.contains(where: { $0.identifier == identifier }) {
            menu.addItem(.separator())
            let arrange = NSMenuItem(title: "", action: #selector(arrangePapers), keyEquivalent: "")
            arrange.identifier = identifier
            arrange.target = self
            menu.addItem(arrange)
            let undo = NSMenuItem(title: "", action: #selector(undoArrangement), keyEquivalent: "")
            undo.identifier = NSUserInterfaceItemIdentifier("foldpin.undoArrangement")
            undo.target = self
            menu.addItem(undo)
        }
        for item in menu.items where item.target === self {
            if item.action == #selector(arrangePapers) {
                item.title = NoteAction.arrange.title(bundle: languageSettings.bundle)
                item.keyEquivalent = NoteAction.arrange.activeKey; item.keyEquivalentModifierMask = NoteAction.arrange.activeModifiers
            } else if item.action == #selector(undoArrangement) {
                item.title = NoteAction.undoArrangement.title(bundle: languageSettings.bundle)
                item.keyEquivalent = NoteAction.undoArrangement.activeKey; item.keyEquivalentModifierMask = NoteAction.undoArrangement.activeModifiers
            }
            item.isEnabled = validateMenuItem(item)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(arrangePapers) { return windows.values.contains { $0.canArrange } }
        if menuItem.action == #selector(undoArrangement) { return canUndoArrangement }
        return true
    }

    @objc func showSettings() {
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

    private var canUndoArrangement: Bool {
        lastArrangement.contains { placement in
            guard let window = windows[placement.id], window.canArrange else { return false }
            return window.paper.frame == placement.after
        }
    }

    @objc private func arrangePapers() {
        let screens = NSScreen.screens
        let fallback = screens.firstIndex(of: workingScreen) ?? 0
        let items = library.entries.compactMap { entry -> NoteArrangement.Item? in
            guard let window = windows[entry.id], window.canArrange else { return nil }
            return NoteArrangement.Item(id: entry.id, frame: window.paper.frame)
        }
        let plan = NoteArrangement.placements(for: items, screens: screens.map(\.visibleFrame), fallback: fallback)
        var moved: [NoteArrangement.Placement] = []
        for placement in plan where placement.before != placement.after {
            guard let window = windows[placement.id], window.moveForArrangement(to: placement.after.origin) else { continue }
            moved.append(placement)
        }
        if !moved.isEmpty { lastArrangement = moved }
        rebuildMenu()
    }

    @objc private func undoArrangement() {
        let screens = NSScreen.screens
        let fallback = screens.firstIndex(of: workingScreen) ?? 0
        var failed: [NoteArrangement.Placement] = []
        for placement in lastArrangement {
            guard let window = windows[placement.id], window.canArrange,
                  let frame = NoteArrangement.undoFrame(for: placement, current: window.paper.frame,
                                                       screens: screens.map(\.visibleFrame), fallback: fallback) else { continue }
            if !window.moveForArrangement(to: frame.origin) { failed.append(placement) }
        }
        lastArrangement = failed
        rebuildMenu()
    }

    @objc private func collapseAll() { setAllCollapsed(true) }
    @objc private func expandAll() { setAllCollapsed(false) }

    private func setAllCollapsed(_ collapsed: Bool) {
        // Shelved and deleted notes stay hidden; reuse each window's save protection.
        let targets = windows.values.filter {
            $0.isVisible && $0.store.loadError == nil && $0.store.isCollapsed != collapsed
        }
        for window in targets { window.toggleCollapsed() }
        rebuildMenu()
    }

    @objc private func shelveAll() {
        var failed: PaperWindowController?
        for window in windows.values where window.isVisible {
            if !window.shelvePaper(restoringFocus: false) { failed = window }
        }
        if let failed { failed.showPaper(focus: true) }
        else { previousApplication?.activate() }
    }

    private func configureShortcuts() {
        shortcutSettings.applyGlobals = { [weak self] bindings in self?.shortcut.register(bindings) ?? -1 }
        shortcut.capture = { binding in
            guard let capture = ShortcutSettings.shared.recordingHandler else { return false }
            capture(binding); return true
        }
        shortcut.onPress = { [weak self] action in
            guard let self else { return }
            switch action {
            case .newNote: newPaper()
            case .quickRecord: quickRecord()
            case .toggleNotes: togglePaper()
            case .shelf: showShelf()
            }
        }
        shortcutSettings.registerGlobals()
        observe(ShortcutSettings.changed) { [weak self] in
            guard let self else { return }
            for entry in library.entries {
                entry.store.shortcutLabel = shortcutSettings.binding(GlobalShortcutAction.toggleNotes).keycaps.joined()
                entry.store.hotKeyStatus = shortcutSettings.globalError == nil ? 0 : -1
            }
            rebuildMenu(); refreshApplicationMenu()
        }
        localShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, shortcutSettings.recordingHandler == nil,
                  NSApp.modalWindow == nil, event.window?.attachedSheet == nil,
                  let action = shortcutSettings.matchingNote(event), ShortcutSettings.appActions.contains(action) else { return event }
            if !event.isARepeat {
                switch action {
                case .newNote: newPaper()
                case .shelf: showShelf()
                case .arrange: arrangePapers()
                case .undoArrangement: undoArrangement()
                case .shelveAll: shelveAll()
                default: break
                }
            }
            return nil
        }
    }

    func searchCurrentNote(_ action: EditorShortcutAction) {
        guard let controller = currentPaper, controller.paper.isKeyWindow else { return }
        controller.search(action)
    }

    private func quickRecord() {
        quickRecording.trigger(canStart: !AudioBlockModel.requestingRecording && library.canCreate, finishCurrent: { [self] in
            if let recording = AudioBlockModel.recording {
                let controller = windows.values.first { $0.audioEditor === recording.editor }
                NSApp.activate(); recording.editor?.window?.makeKeyAndOrderFront(nil)
                let saved = recording.finish()
                recordingSaveRetryID = saved ? nil : controller?.id
                return saved
            }
            if let id = recordingSaveRetryID, let controller = windows[id] {
                controller.showPaper(focus: true)
                let saved = controller.prepareToTerminate()
                if saved { recordingSaveRetryID = nil }
                return saved
            }
            return nil
        }, permission: {
            return await AVCaptureDevice.requestAccess(for: .audio)
        }, start: { [weak self] in
            guard let self else { return }
            guard let entry = library.createNote() else { showShelf(); return }
            let controller = controller(for: entry)
            await controller.startQuickRecording()
            if entry.store.saveError != nil { recordingSaveRetryID = entry.id }
            updateEdge(); rebuildMenu()
        }, denied: { [weak self] in
            guard let self else { return }
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = String(localized: "Allow microphone access for Foldpin in System Settings to record audio.", bundle: languageSettings.bundle)
            alert.runModal()
        }, finished: { AudioBlockModel.requestingRecording = false })
        // Reserve capture synchronously before the permission task begins.
        if quickRecording.isStarting { AudioBlockModel.requestingRecording = true }
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
        shortcutSettings.applyGlobals = nil
        if let localShortcutMonitor { NSEvent.removeMonitor(localShortcutMonitor) }
        shortcut.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        languageSubscription?.cancel()
        for window in windows.values { window.dispose() }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
