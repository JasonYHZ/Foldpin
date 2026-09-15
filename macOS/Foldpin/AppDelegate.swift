import AppKit
import SwiftUI
import Combine
import AVFoundation
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let languageSettings = LanguageSettings.shared
    let storage = LibraryLocationController()
    let login = LoginItemSettings()
    lazy var mcp = MCPServer(commands: FoldpinCommandService(library: { [unowned self] in self.library }, journal: MCPJournal(directory: storage.library.path.localDirectory.appendingPathComponent("mcp-receipts"))))
    private let mcpApprovals = MCPApprovalCenter()
    private let gettingStarted = GettingStartedNote()
    private let feedbackController = FeedbackController()
    private let markdownImporter = MarkdownFileImportController()
    private var backgroundLaunch = false
    private var launched = false
    private var attemptedFirstNote = false
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

    func applicationWillFinishLaunching(_ notification: Notification) {
        backgroundLaunch = LoginItemSettings.isBackgroundLaunch
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        backgroundLaunch = backgroundLaunch || LoginItemSettings.isBackgroundLaunch
        launched = true
        if storage.firstRunCandidate { UserDefaults.standard.set(true, forKey: "gettingStarted.eligible") }
        markdownImporter.onOpen = { [weak self] in self?.locateNote($0) }
        storage.prepare = { [weak self] in
            guard let self else { return }
            guard LibraryFileActivity.exports == 0, LibraryFileActivity.imports == 0, !AudioBlockModel.requestingRecording,
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
            considerGettingStarted()
        }
        storage.willRefresh = { [weak self] in
            guard let self else { return false }
            guard LibraryFileActivity.imports == 0, windows.values.allSatisfy({ !$0.session.host.editor.hasPendingLibraryWork && !$0.session.host.editor.hasMarkedText()
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
        configureMCP()
        mcp.start()
        for entry in library.entries where !entry.store.document.isShelved || entry.store.loadError != nil {
            controller(for: entry).showPaper(focus: false)
            lastActiveID = entry.id
        }
        updateEdge()
        if library.failure != nil && !backgroundLaunch { DispatchQueue.main.async { [weak self] in self?.showShelf() } }
        DispatchQueue.main.async { [weak self] in self?.considerGettingStarted() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        login.refresh()
        if launched { considerGettingStarted() }
    }
    private func considerGettingStarted() {
        guard !backgroundLaunch, !attemptedFirstNote, !gettingStarted.completed, storage.isGettingStartedLibrary,
              !storage.isBusy, library.canCreate else { return }
        attemptedFirstNote = true
        do {
            if let entry = try gettingStarted.createOnFirstLaunch(in: library, eligible: true,
                bundle: languageSettings.bundle, shortcuts: shortcutSettings) { showGuideNote(entry) }
        } catch { showGuideError(error) }
    }
    func showQuickStart() {
        do { showGuideNote(try gettingStarted.open(in: library, bundle: languageSettings.bundle, shortcuts: shortcutSettings)) }
        catch { showGuideError(error) }
    }
    private func showGuideNote(_ entry: NoteLibrary.Entry) {
        if entry.store.document.deletedAt != nil { locateNote(entry.id); return }
        let screen = workingScreen.visibleFrame
        let width = min(520, screen.width), height = min(680, screen.height)
        let frame = NSRect(x: screen.midX - width / 2, y: screen.midY - height / 2, width: width, height: height)
        controller(for: entry, initialFrame: frame).showPaper(focus: true)
    }
    private func showGuideError(_ error: Error) {
        let alert = NSAlert(); alert.messageText = readinessText("Could not open the guide note")
        alert.informativeText = error.localizedDescription; alert.runModal()
    }
    func showFeedback() { feedbackController.show() }
    func importMarkdown() {
        markdownImporter.choose(storage: storage)
    }
    func locateNote(_ id: UUID) {
        showShelf(); shelfWindow?.revealNote(id)
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
        shelfWindow?.onImport = { [weak self] in self?.importMarkdown() }
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
        backgroundLaunch = false
        considerGettingStarted()
        if let current = currentPaper { current.showPaper(focus: true) } else { showShelf() }
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if LibraryFileActivity.exports > 0 || (LibraryFileActivity.imports > 0 && !markdownImporter.busy) { return .terminateCancel }
        if markdownImporter.busy {
            markdownImporter.show()
            let alert = NSAlert(); alert.messageText = readinessText("Finish or cancel the import before quitting."); alert.runModal()
            return .terminateCancel
        }
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
        mcp.stop()
        shortcutSettings.applyGlobals = nil
        if let localShortcutMonitor { NSEvent.removeMonitor(localShortcutMonitor) }
        shortcut.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        languageSubscription?.cancel()
        for window in windows.values { window.dispose() }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

extension AppDelegate {
    private func configureMCP() {
        let service=mcp.commands
        service.isBusy={ [weak self] id in
            guard let self else{return true}
            if storage.isBusy || storage.isRefreshing || LibraryFileActivity.imports>0 || LibraryFileActivity.exports>0 {return true}
            if let id{return windows[id]?.session.host.editor.mcpInteractionBusy ?? false}
            return false
        }
        service.commitContent={ [weak self] entry,content in
            if let editor=self?.windows[entry.id]?.session.host.editor{try editor.applyCommandContent(content)}else{entry.store.edit(content)}
            guard entry.store.flush() else{throw MCPFailure("save_failed")}
        }
        service.didChange={ [weak self] in
            guard let self else{return}
            let existingIDs=Set((library.entries + library.deletedEntries).map(\.id))
            for (id,controller) in windows where controller.store.document.deletedAt != nil || !existingIDs.contains(id){controller.hideDeletedPaper()}
            shelfWindow?.collections.reload();rebuildMenu();updateEdge()
        }
        service.native={ [weak self] name,args,grant in guard let self else{throw MCPFailure("library_unavailable")};return try await performMCP(name,args,grant) }
        service.requestConfirmation={ [weak self] id,name,args,grant in
            guard let self else{return};mcpApprovals.show(id:id,name:name,args:args,grant:grant,service:service)
        }
    }
    private func performMCP(_ name:String,_ args:[String:Any],_ grant:MCPGrant) async throws -> [String:Any] {
        let service=mcp.commands,op=String(name.dropFirst("foldpin_".count))
        func target() throws -> NoteLibrary.Entry {try service.entry(args.uuid("noteId"),grant,deleted:false)}
        func result(_ e:NoteLibrary.Entry) throws -> [String:Any]{["noteId":e.id.uuidString,"revision":try MCPJSON.revision(e.store.document)]}
        switch op {
        case "show_notes","shelve_notes":
            guard let targets=args["targets"] as? [[String:Any]],!targets.isEmpty else{throw MCPFailure("invalid_input")}
            var results:[[String:Any]]=[]
            for t in targets{
                let id=try t.uuid("noteId")
                do {
                    let e=try service.entry(id,grant,deleted:false);try service.check(e,revision:try t.string("expectedRevision"))
                    if op=="show_notes"{controller(for:e).showPaper(focus:args.bool("activate"))}
                    else if let c=windows[e.id]{guard c.shelvePaper(restoringFocus:false) else{throw MCPFailure("save_failed")}}
                    else{e.store.setShelved(true)}
                    guard e.store.flush() else{throw MCPFailure("save_failed")}
                    var item=try result(e);item["status"]="completed";results.append(item)
                } catch { results.append(["noteId":id.uuidString,"status":"failed","error":(error as? MCPFailure)?.code ?? "save_failed"]) }
            };return ["results":results]
        case "close_note":
            let e=try target()
            if e.store.document.content.isBlankForClosing{
                guard grant.permissions.contains(.trash) else{throw MCPFailure("permission_denied")}
                guard library.deleteNote(e.id) else{throw MCPFailure("save_failed")};windows[e.id]?.hideDeletedPaper()
            }else if let c=windows[e.id]{guard c.shelvePaper(restoringFocus:false) else{throw MCPFailure("save_failed")}}
            else{e.store.setShelved(true);guard e.store.flush() else{throw MCPFailure("save_failed")}}
            return try result(e)
        case "set_window_state":
            let e=try target(),frame=try args["frame"].map{try MCPJSON.decode(NoteFrame.self,$0)}
            if let c=windows[e.id]{try c.applyCommandWindowState(pinned:args["pinned"] as? Bool,collapsed:args["collapsed"] as? Bool,frame:frame)}
            else{
                if let v=args["pinned"] as? Bool{e.store.setPinned(v)};if let v=args["collapsed"] as? Bool{e.store.setCollapsed(v)}
                if let frame{e.store.setFrame(frame.fitted(to:NSScreen.screens.map(\.visibleFrame),fallback:workingScreen.visibleFrame))}
                guard e.store.flush() else{throw MCPFailure("save_failed")}
            };return try result(e)
        case "arrange_windows","undo_arrangement":
            guard grant.noteIDs==nil else{throw MCPFailure("permission_denied")}
            let candidates=windows.filter{$0.value.canArrange}
            let before=candidates.mapValues{$0.paper.frame}
            if op=="arrange_windows"{arrangePapers()}else{undoArrangement()}
            return ["status":"completed","results":candidates.map{id,controller in
                if controller.store.saveError != nil{return ["noteId":id.uuidString,"status":"failed","error":"save_failed"] as [String:Any]}
                return ["noteId":id.uuidString,"status":"completed","moved":before[id] != controller.paper.frame] as [String:Any]
            }]
        case "show_shelf":showShelf();return ["status":"completed"]
        case "show_settings":showSettings();return ["status":"accepted"]
        case "update_settings":
            guard try service.settings()["revision"] as? String == args.string("expectedRevision") else{throw MCPFailure("revision_conflict")}
            if let value=args["theme"] as? String{ThemeSettings.shared.select(AppTheme(rawValue:value)!)}
            if let value=args["language"] as? String{languageSettings.select(AppLanguage(rawValue:value)!)}
            if let value=args["appearance"] as? String{UserDefaults.standard.set(value,forKey:NoteAppearance.preferenceKey)}
            return try service.settings()
        case "copy_content","copy_image","copy_block":
            let e=try target();guard grant.permissions.contains(.read) else{throw MCPFailure("permission_denied")}
            let content:NoteContent
            if op=="copy_content"{content=e.store.document.content}
            else{guard let b=e.store.document.content.blocks.first(where:{$0.id == (try? args.uuid("blockId"))}) else{throw MCPFailure("not_found_or_denied")};content=NoteContent(blocks:[b])}
            if content.blocks.contains(where:{$0.image != nil || $0.audio != nil || $0.video != nil || $0.attachment != nil}),!grant.permissions.contains(.assets){throw MCPFailure("permission_denied")}
            if op=="copy_image"{guard let image=content.blocks.first?.image else{throw MCPFailure("invalid_input")};try NoteClipboard.copyImage(image,file:e.store.file)}
            else{try NoteClipboard.copy(content,file:e.store.file)}
            return ["status":"completed"]
        case "paste_clipboard":
            guard grant.permissions.contains(.edit) else{throw MCPFailure("permission_denied")}
            let e=try target()
            let snapshot=try MCPClipboard.capture(.general,allowAssets:grant.permissions.contains(.assets)){block in
                for entry in self.library.entries where service.allowed(entry.id,grant) {
                    for existing in entry.store.document.content.blocks where existing.image==block.image && existing.audio==block.audio && existing.video==block.video && existing.attachment==block.attachment {
                        if (try? service.assetURL(entry,blockID:existing.id)) != nil{return true}
                    }
                }
                return false
            }
            let assets=e.store.file.assetsURL
            LibraryFileActivity.imports+=1
            let pasted:NoteContent
            do{pasted=try await Task.detached{try await snapshot.prepare(assets:assets)}.value}
            catch{LibraryFileActivity.imports-=1;throw error}
            LibraryFileActivity.imports-=1
            try service.ensureCurrent(grant,args:args)
            var content=e.store.document.content;content.blocks += pasted.blocks
            return try service.saveContent(content,e,grant)
        case "play_media","pause_media","seek_media","set_playback":
            let e=try target();guard grant.permissions.contains(.assets) else{throw MCPFailure("permission_denied")}
            let id=try args.uuid("blockId");_ = try service.assetURL(e,blockID:id)
            try controller(for:e).session.host.editor.commandMedia(op,blockID:id,position:(args["position"] as? NSNumber)?.doubleValue,rate:(args["rate"] as? NSNumber)?.floatValue)
            return try result(e)
        case "start_recording":
            guard grant.permissions.contains(.edit),AudioBlockModel.recording==nil,!AudioBlockModel.requestingRecording else{throw MCPFailure("busy_editing")}
            let e=try target();AudioBlockModel.requestingRecording=true
            let allowed=await AVCaptureDevice.requestAccess(for:.audio);AudioBlockModel.requestingRecording=false
            guard allowed else{throw MCPFailure("permission_denied")};try service.ensureCurrent(grant,args:args)
            let c=controller(for:e);c.showPaper(focus:true);c.session.host.editor.startAuthorizedRecording(source:e.store.document.content.blocks.last)
            guard let recording=AudioBlockModel.recording,recording.editor === c.session.host.editor else{throw MCPFailure("save_failed")}
            var out=try result(e);out["recordingSessionId"]=recording.blockID.uuidString;return out
        case "pause_recording","resume_recording":
            let e=try target();guard let recording=AudioBlockModel.recording,recording.file.url == e.store.file.url else{throw MCPFailure("not_found_or_denied")}
            let paused=op=="pause_recording"
            if recording.isPaused != paused{recording.toggleRecordingPause()}
            guard recording.isPaused==paused else{throw MCPFailure("save_failed")}
            return ["status":"completed","paused":recording.isPaused,"recordingSessionId":recording.blockID.uuidString]
        case "stop_recording":
            let e=try target();guard let recording=AudioBlockModel.recording,recording.file.url == e.store.file.url else{throw MCPFailure("not_found_or_denied")}
            guard recording.finish() else{throw MCPFailure("save_failed")};return try result(e)
        case "open_attachment","reveal_file":
            guard grant.permissions.contains(.assets) else{throw MCPFailure("permission_denied")}
            let e=try target(),url=try service.assetURL(e,blockID:args.uuid("blockId"))
            if op=="reveal_file"{NSWorkspace.shared.activateFileViewerSelecting([url])}
            else{
                let dangerous=Set(["app","command","sh","bash","zsh","scpt","workflow","pkg","dmg","webloc","url"])
                guard !dangerous.contains(url.pathExtension.lowercased()) else{throw MCPFailure("unsupported")}
                guard NSWorkspace.shared.open(url) else{throw MCPFailure("asset_unavailable")}
            };return ["status":"completed"]
        case "export_notes","export_asset":
            guard grant.permissions.contains(.read) else{throw MCPFailure("permission_denied")}
            let entries: [NoteLibrary.Entry]
            if let targets=args["targets"] as? [[String:Any]], !targets.isEmpty, args["noteId"] == nil {
                entries=try targets.map { try service.entry($0.uuid("noteId"),grant) }
            } else { entries=[try target()] }
            let sources=entries.map { NoteExportSource(document:$0.store.document,assets:$0.store.file.assetsURL) }
            if sources.contains(where: \.hasResources) && !grant.permissions.contains(.assets){throw MCPFailure("permission_denied")}
            let panel=NSSavePanel();panel.canCreateDirectories=true;let format=NoteExportFormat(rawValue:args["format"] as? String ?? "markdown")!
            let media: MediaExport?
            if op=="export_asset" {
                let id=try args.uuid("blockId"),url=try service.assetURL(entries[0],blockID:id)
                guard let block=entries[0].store.document.content.blocks.first(where:{$0.id==id}) else{throw MCPFailure("not_found_or_denied")}
                if let image=block.image{media=try MediaExport.image(at:url,name:image.name,fallback:"Image",isSVG:image.isSVG == true)}
                else if let audio=block.audio{media=try MediaExport.audio(at:url,audio:audio,fallback:"Audio")}
                else if let video=block.video{media=try MediaExport.video(at:url,video:video,fallback:"Video")}
                else if let attachment=block.attachment{media=try MediaExport.attachment(at:url,attachment:attachment)}
                else{throw MCPFailure("asset_unavailable")}
            } else { media=nil }
            panel.nameFieldStringValue=media?.filename ?? (sources.count==1 ? NoteExport.filename(sources[0].title) : "Foldpin")+"."+(NoteExport.isArchive(sources) ? "zip" : format.fileExtension)
            if let media{panel.allowedContentTypes=[media.contentType]}
            service.cancelNative = { panel.cancel(nil) }
            let answer=await panel.begin();guard answer == .OK,let url=panel.url else{throw MCPFailure("cancelled")}
            try service.ensureCurrent(grant,args:args)
            LibraryFileActivity.exports+=1;defer{LibraryFileActivity.exports-=1}
            if let media{
                try await Task.detached{try media.write(to:url)}.value
            }else{try await Task.detached{try NoteExport.write(sources,format:format,to:url)}.value}
            return ["status":"completed"]
        case "import_asset":
            let e=try target(),kind=try args.string("type")
            let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
            guard await panel.begin() == .OK,let url=panel.url else{throw MCPFailure("cancelled")}
            try service.ensureCurrent(grant,args:args)
            let assets=e.store.file.assetsURL
            LibraryFileActivity.imports+=1
            let block:NoteBlock
            do{
                block=try await Task.detached{() async throws -> NoteBlock in
                    switch kind{
                    case "image":return NoteBlock(kind:.image,image:try NoteImageImporter.prepare(url:url,directory:assets).image)
                    case "audio":return NoteBlock(kind:.audio,audio:try NoteAudioImporter.prepare(url:url,directory:assets))
                    case "video":return NoteBlock(kind:.video,video:try await NoteVideoImporter.prepare(url:url,directory:assets))
                    default:return NoteBlock(kind:.file,attachment:try NoteAttachmentImporter.prepare(urls:[url],directory:assets.appendingPathComponent("files"))[0])
                    }
                }.value
            }catch{LibraryFileActivity.imports-=1;throw error}
            LibraryFileActivity.imports-=1
            try service.ensureCurrent(grant,args:args)
            var next=e.store.document.content;next.blocks.append(block);return try service.saveContent(next,e,grant)
        case "get_shortcuts":
            let bindings = try MCPJSON.object(shortcutSettings.overrides)
            let resolved = try ShortcutSettings.allIDs.map { id in ["id":id,"title":shortcutSettings.title(id),"binding":try MCPJSON.object(shortcutSettings.binding(id))] as [String:Any] }
            return ["status":"completed","shortcuts":resolved,"revision":try MCPJSON.hash(bindings)]
        case "set_shortcut":
            guard try MCPJSON.hash(MCPJSON.object(shortcutSettings.overrides)) == args.string("expectedRevision") else { throw MCPFailure("revision_conflict") }
            let binding = args.bool("clear") ? ShortcutBinding.disabled : ShortcutBinding(code: UInt16(args.int("keyCode")), modifiers: NSEvent.ModifierFlags(rawValue:UInt(args.int("modifierBits"))))
            guard binding.isValid, shortcutSettings.set(binding,for:try args.string("shortcutId")) else { throw MCPFailure("invalid_input") }
            return ["revision":try MCPJSON.hash(MCPJSON.object(shortcutSettings.overrides))]
        case "list_code_themes": return try mcpCodeThemes()
        case "set_code_theme", "remove_code_theme":
            let themes=CodeThemeSettings.shared
            guard try mcpCodeThemes()["revision"] as? String == args.string("expectedRevision") else { throw MCPFailure("revision_conflict") }
            if let id=args["themeId"] as? String {
                guard let choice=themes.choices.first(where:{$0.id==id}),op != "remove_code_theme" || choice.imported else { throw MCPFailure("invalid_input") }
                let previous=themes.selection
                themes.select(id)
                if op=="remove_code_theme" {
                    defer{if previous != id{themes.select(previous)}}
                    try themes.removeSelectedImport()
                }
            }
            if let value=args["backgroundOpacity"] as? NSNumber { themes.setBackgroundOpacity(value.doubleValue) }
            return try mcpCodeThemes()
        case "import_code_theme":
            let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
            guard await panel.begin() == .OK,let url=panel.url else {throw MCPFailure("cancelled")}
            try service.ensureCurrent(grant,args:args)
            let scoped=url.startAccessingSecurityScopedResource();defer{if scoped{url.stopAccessingSecurityScopedResource()}}
            let definition=try CodeThemeLoader.load(url,allowedDirectory:url.deletingLastPathComponent())
            try CodeThemeSettings.shared.install(definition);return try mcpCodeThemes()
        case "get_login_status": login.refresh();return ["status":"completed","enabled":login.enabled,"systemStatus":login.status.rawValue]
        case "set_login_enabled":
            await login.setEnabled(args.bool("enabled"))
            if login.error != nil { throw MCPFailure("system_approval_required") }
            return ["status":"completed","enabled":login.enabled,"systemStatus":login.status.rawValue]
        case "show_help":guard grant.permissions.contains(.create),grant.noteIDs==nil else{throw MCPFailure("permission_denied")};showQuickStart();return ["status":"accepted"]
        case "show_feedback":showFeedback();return ["status":"accepted"]
        case "get_library_location":return ["status":"completed","libraryId":service.libraryID,"revision":String(library.path.writeSerial),"formatVersion":library.path.manifest?.version ?? 0]
        case "change_library_location":
            guard grant.noteIDs==nil,try args.string("expectedRevision")==String(library.path.writeSerial) else{throw MCPFailure("revision_conflict")}
            let original=library,serial=library.path.writeSerial
            try await storage.commandChangeLocation(try args.string("action")) {
                try service.ensureCurrent(grant,args:args)
                guard self.library === original, original.path.writeSerial == serial else { throw MCPFailure("revision_conflict") }
            }
            service.cancelNative = { [weak self] in self?.storage.cancel() }
            while storage.isBusy { try await Task.sleep(for:.milliseconds(100)) }
            if storage.failure != nil { throw MCPFailure("library_unavailable") }
            return ["status":"completed","libraryId":service.libraryID]
        case "scan_storage":
            guard grant.noteIDs==nil else{throw MCPFailure("permission_denied")}
            let root=library.directory,serial=library.path.writeSerial
            let task=Task.detached{try LibraryUsage.scan(root:root)};service.cancelNative={task.cancel()}
            let report=try await task.value
            try service.ensureCurrent(grant,args:args);guard library.path.writeSerial==serial,library.directory==root else{throw MCPFailure("revision_conflict")}
            return ["status":"completed","totalBytes":report.total,"incomplete":report.incomplete,
                "categories":LibraryUsage.Category.allCases.map{["category":$0.rawValue,"bytes":report.bytes($0)] as [String:Any]},
                "largeResources":report.largestResources.prefix(50).map{["bytes":$0.bytes,"noteIds":$0.references.map{ $0.noteID.uuidString }] as [String:Any]}]
        case "import_markdown":
            guard grant.noteIDs==nil,grant.permissions.contains(.edit),!markdownImporter.busy else{throw MCPFailure("permission_denied")}
            let panel=NSOpenPanel();panel.allowsMultipleSelection=true;panel.canChooseDirectories=false
            guard await panel.begin() == .OK,!panel.urls.isEmpty,panel.urls.count<=50 else{throw MCPFailure("cancelled")}
            let sources=panel.urls;var resourceRoot:URL?
            if args.bool("includeResources") {
                let folder=NSOpenPanel();folder.canChooseFiles=false;folder.canChooseDirectories=true;folder.allowsMultipleSelection=false
                guard await folder.begin() == .OK,let url=folder.url else{throw MCPFailure("cancelled")};resourceRoot=url
            }
            try service.ensureCurrent(grant,args:args)
            markdownImporter.configure(sources:sources,storage:storage,resourceRoot:resourceRoot)
            markdownImporter.skipUnresolved=args.bool("skipUnresolved");markdownImporter.run()
            service.cancelNative={ [weak self] in self?.markdownImporter.cancel() }
            while markdownImporter.busy { try await Task.sleep(for:.milliseconds(100)) }
            return ["status":"completed","results":markdownImporter.rows.map{["noteId":$0.noteID.uuidString,"status":$0.state,"succeeded":$0.succeeded,"warningCount":$0.warnings.count] as [String:Any]}]
        case "quit":DispatchQueue.main.asyncAfter(deadline:.now()+0.2){NSApp.terminate(nil)};return ["status":"accepted"]
        default:throw MCPFailure("unsupported")
        }
    }
}

extension AppDelegate {
    private func mcpCodeThemes() throws -> [String:Any] {
        let t=CodeThemeSettings.shared
        let value:[String:Any]=["themes":t.choices.map{["id":$0.id,"name":$0.name,"imported":$0.imported] as [String:Any]},"selected":t.selection,"backgroundOpacity":t.backgroundOpacity]
        var result=value;result["revision"]=try MCPJSON.hash(value);result["status"]="completed";return result
    }
}
