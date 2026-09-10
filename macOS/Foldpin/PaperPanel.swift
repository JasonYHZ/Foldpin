import AppKit

final class PaperPanel: NSPanel {
    var onActivate: (() -> Void)?
    var onToggleCollapsed: (() -> Void)?
    var onRequestClose: (() -> Void)?
    var onEndResize: (() -> Void)?
    var onBeginMove: (() -> Void)?
    var onFindHistory: ((NSEvent) -> Bool)?
    var onSearch: ((EditorShortcutAction) -> Void)?
    var onAction: ((NoteAction) -> Void)?
    var onShortcutHints: ((Bool) -> Void)?
    private var commandHintWork: DispatchWorkItem?
    private var commandIsDown = false
    private var shortcutMonitor: Any?
    private var resizeSession: ResizeSession?
    var isResizingByMouse: Bool { resizeSession != nil }

    private struct ResizeSession {
        let edges: NoteResizeEdges
        let initialFrame: NSRect
        let initialPointer: NSPoint
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        // A new press starts a new gesture even if the previous mouse-up was
        // lost while switching screens or focus. Never reuse its resize origin.
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            finishResize()
        }
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
        // Explicit interaction activates this document. Passive restoration
        // only orders it front without requesting key/main focus.
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            onActivate?()
        }
        let contextClick = event.type == .rightMouseDown ||
            (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        if contextClick, let surface = contentView as? NoteWindowSurface,
           let region = surface.titlebarDragRegion(at: event.locationInWindow) {
            region.showColorMenu(with: event)
            return
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

    override func performDrag(with event: NSEvent) {
        finishResize()
        onBeginMove?()
        // WindowServer still owns movement and Space switching. This returns
        // immediately, so do not treat its return as the end of the gesture.
        super.performDrag(with: event)
    }

    private func finishResize() {
        guard resizeSession != nil else { return }
        resizeSession = nil
        onEndResize?()
    }

    override func becomeKey() {
        super.becomeKey()
        // Observe before the application menu consumes Copy/Paste/etc. This
        // local monitor exists only while this paper owns keyboard focus.
        guard shortcutMonitor == nil else { return }
        commandIsDown = NSEvent.modifierFlags.contains(.command)
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isKeyWindow, NSApp.isActive else { return event }
            if event.type == .flagsChanged { self.updateCommandHold(event.modifierFlags) }
            else { self.cancelShortcutHints() }
            return event
        }
    }

    override func resignKey() {
        finishResize()
        cancelShortcutHints()
        commandIsDown = false
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor); self.shortcutMonitor = nil }
        super.resignKey()
    }

    private func updateCommandHold(_ flags: NSEvent.ModifierFlags) {
        let modifiers = flags.intersection([.command, .control, .option, .shift])
        let wasDown = commandIsDown
        commandIsDown = modifiers.contains(.command)
        guard modifiers == .command, isKeyWindow, NSApp.isActive else {
            cancelShortcutHints()
            return
        }
        guard !wasDown else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isKeyWindow, NSApp.isActive, self.commandIsDown else { return }
            self.onShortcutHints?(true)
        }
        commandHintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    func cancelShortcutHints() {
        commandHintWork?.cancel()
        commandHintWork = nil
        onShortcutHints?(false)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        cancelShortcutHints()
        if isKeyWindow, ShortcutSettings.shared.recordingHandler == nil, onFindHistory?(event) == true { return true }
        if isKeyWindow, let action = ShortcutSettings.shared.matchingEditor(event), action.isSearch, let onSearch {
            if !event.isARepeat { onSearch(action) }
            return true
        }
        if isKeyWindow, event.type == .keyDown, let onAction,
           let action = ShortcutSettings.shared.matchingNote(event) {
            if !event.isARepeat { onAction(action) }
            return true
        }
        return super.performKeyEquivalent(with: event)
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
