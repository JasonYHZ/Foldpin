import AppKit

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
