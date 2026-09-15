import AppKit
import SwiftUI
import Foundation

/// One native glass surface behind the existing editor and controls.
@MainActor
final class NoteWindowSurface: NSView {
    private let hosting: NSView
    private let glass = NSGlassEffectView()
    private let edge = NoteEdgeView()
    private let resizeHandles = NoteResizeHandleView()
    private var usesGlass: Bool?
    private var material: NoteAppearance = .paper
    private(set) var color: NoteColor = .original
    private weak var dragRegion: NoteWindowDragView?
    private var preferenceObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    private var hoverTrackingArea: NSTrackingArea?
    private weak var observedWindow: NSWindow?
    private var pointerRefreshScheduled = false
    private var isPointerInside = false
    private let onHoverChange: ((Bool) -> Void)?

    init(content: NSView, onHoverChange: ((Bool) -> Void)? = nil) {
        hosting = content
        self.onHoverChange = onHoverChange
        super.init(frame: .zero)
        // Clip the entire native surface, not just SwiftUI's content. This
        // keeps composited content inside the same corners in either material.
        wantsLayer = true
        layer?.cornerRadius = NoteWindowStyle.cornerRadius
        layer?.masksToBounds = true
        glass.cornerRadius = NoteWindowStyle.cornerRadius
        glass.style = .regular
        addSubview(glass)
        edge.setAccessibilityElement(false)
        addSubview(edge)
        resizeHandles.setAccessibilityElement(false)
        addSubview(resizeHandles)
        refreshAppearance()
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAppearance() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(noteStyleChanged(_:)), name: NoteStyleSettings.didChange, object: NoteStyleSettings.shared)
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAppearance() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if hoverTrackingArea == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            hoverTrackingArea = area
        }
        schedulePointerRefresh()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setPointerInside(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setPointerInside(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observedWindow { NotificationCenter.default.removeObserver(self, name: nil, object: observedWindow) }
        observedWindow = window
        if let window {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeOcclusionStateNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowGeometryChanged(_:)), name: name, object: window)
            }
        }
        schedulePointerRefresh()
    }

    @objc private func windowGeometryChanged(_ notification: Notification) { schedulePointerRefresh() }

    private func schedulePointerRefresh() {
        guard !pointerRefreshScheduled else { return }
        pointerRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            pointerRefreshScheduled = false
            refreshPointerPresence()
        }
    }

    func refreshPointerPresence() {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { setPointerInside(false); return }
        let mouse = NSEvent.mouseLocation
        let point = convert(window.convertPoint(fromScreen: mouse), from: nil)
        let radius = NoteWindowStyle.resolvedCornerRadius(for: bounds.size)
        let inside = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).contains(point)
        // A different paper or application covering this window is not a hover.
        setPointerInside(inside && NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0) == window.windowNumber)
    }

    private func setPointerInside(_ value: Bool) {
        guard isPointerInside != value else { return }
        isPointerInside = value
        onHoverChange?(value)
    }

    override func draw(_ dirtyRect: NSRect) {
        // WindowServer's transparent-window hit region must include the paper
        // itself, not only AppKit text/dividers. A SwiftUI-only background can
        // look filled while clicks pass through its composited surface.
        if usesGlass == true {
            // The compositor's glass is not sufficient to define a native
            // WindowServer hit region. A nearly transparent backing makes the
            // whole sheet (including resize edges) receive clicks reliably.
            // It sits behind the glass and preserves its blur/translucency.
            NSColor.windowBackgroundColor.withAlphaComponent(0.02).setFill()
            bounds.fill()
        } else {
            (material == .paper ? NotePalette.paperBackground(for: color)
                : NotePalette.solidGlassBackground(for: color))
                .withAlphaComponent(material == .paper && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                    && !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? NoteStyleSettings.shared.values.paperOpacity : 1).setFill()
            bounds.fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshSurfaceColors()
    }

    func updateColor(_ color: NoteColor) {
        guard self.color != color else { return }
        self.color = color
        refreshSurfaceColors()
    }

    private func refreshSurfaceColors() {
        // Resolve the native glass tint under this window's actual appearance;
        // do not leave its compositor holding the previous theme's RGB value.
        var tint: NSColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tint = material == .translucent ? NotePalette.glassTint(for: color)?.usingColorSpace(.sRGB) : nil
        }
        if glass.tintColor != tint { glass.tintColor = tint }
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let radius = NoteWindowStyle.resolvedCornerRadius(for: newSize)
        layer?.cornerRadius = radius
        glass.cornerRadius = radius
        needsDisplay = true
        schedulePointerRefresh()
    }

    func resizeEdges(at windowPoint: NSPoint) -> NoteResizeEdges {
        guard let window, window.styleMask.contains(.resizable) else { return [] }
        // Event routing uses the actual surface bounds, even before an overlay
        // layout pass catches up after a material switch or a window resize.
        return NoteResizeEdges.hit(at: convert(windowPoint, from: nil), in: bounds,
                                   allowsVertical: window.maxSize.height > window.minSize.height)
    }

    func titlebarDragRegion(at windowPoint: NSPoint) -> NoteWindowDragView? {
        if dragRegion?.isDescendant(of: hosting) != true {
            dragRegion = findDragRegion(in: hosting)
        }
        guard let dragRegion, !dragRegion.isHiddenOrHasHiddenAncestor else { return nil }
        // SwiftUI can allow drawing outside the representable, so visibleRect
        // may exceed its bounds. Never treat that overflow as draggable space.
        return dragRegion.containsDragPoint(windowPoint) ? dragRegion : nil
    }

    private func findDragRegion(in view: NSView) -> NoteWindowDragView? {
        for child in view.subviews {
            if let region = child as? NoteWindowDragView { return region }
            if let region = findDragRegion(in: child) { return region }
        }
        return nil
    }

    override func layout() {
        super.layout()
        // Fill the borderless panel: an inset leaves a second outline around
        // the glass instead of a single rounded sheet.
        let surface = bounds
        guard surface.width > 0, surface.height > 0 else { return }
        if glass.frame != surface { glass.frame = surface }
        if usesGlass != true, hosting.frame != surface { hosting.frame = surface }
        if edge.frame != surface { edge.frame = surface }
        if resizeHandles.frame != surface { resizeHandles.frame = surface }
        window?.invalidateCursorRects(for: resizeHandles)
    }

    @objc private func noteStyleChanged(_ notification: Notification) { refreshAppearance() }

    private func refreshAppearance() {
        glass.style = NoteStyleSettings.shared.values.clearGlass ? .clear : .regular
        let choice = NoteAppearance(rawValue: UserDefaults.standard.string(forKey: NoteAppearance.preferenceKey) ?? "") ?? .paper
        material = choice
        let workspace = NSWorkspace.shared
        let enabled = choice == .translucent && !workspace.accessibilityDisplayShouldReduceTransparency
            && !workspace.accessibilityDisplayShouldIncreaseContrast
        edge.isPaper = choice == .paper
        edge.needsDisplay = true
        refreshSurfaceColors()
        guard usesGlass != enabled else { return }
        let responder = window?.firstResponder as? NSView
        let restoreResponder = responder?.isDescendant(of: hosting) == true
        // Reparent the same hosting view; never rebuild NSTextView or its undo stack.
        if enabled {
            hosting.removeFromSuperview()
            glass.contentView = hosting
            glass.isHidden = false
        } else {
            glass.contentView = nil
            glass.isHidden = true
            addSubview(hosting, positioned: .below, relativeTo: edge)
        }
        usesGlass = enabled
        needsDisplay = true
        needsLayout = true
        schedulePointerRefresh()
        if restoreResponder, let responder { window?.makeFirstResponder(responder) }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }
}

final class TransparentNoteHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}
